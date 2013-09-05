###
#  Copyright (C) 2013 - Raphael Derosso Pereira <raphaelpereira@gmail.com>
#
#  Backbone.RailsStore - version 1.0.3
#
#  Backbone extensions to provide complete Rails interaction on CoffeeScript/Javascript,
#  keeping single reference models in memory, reporting refresh conflicts and consistently
#  persisting models and there relations.
#
#  Backbone.RailsStore may be freely distributed under the MIT license.
#
###

class ErrorTransportException < RuntimeError
  attr :errors

  def initialize(errors)
    @errors = errors
  end

end

class BackboneRailsStoreController < ApplicationController
  skip_before_filter :authenticated, :only => 'authenticate'

  def authenticate
    response = {}
    begin
      ActiveRecord::Base.transaction do
        if params[:authModel]
          klass = params[:authModel][:railsClass]
          model = acl_scoped_class(klass, :read).where(:login => params[:authModel][:model][:login], :active => true).first
          raise_error_hash(klass, 'no read permission') unless model
          if model
            token = params[:authModel][:model][:token]
            hash = Digest::SHA1.hexdigest("#{token}#{model.password}")
            if hash == params[:authModel][:model][:hash]
              response = {}
              response[:authModel] = {
                  :railsClass => klass,
                  :id => model.id
              }
              response.merge! (refresh_models({
                  :"#{klass}" => {
                      :railsClass => klass,
                      :ids => [model.id]
                  }
                                       }))
              session[:current_user] = model.id if model
            end
          end
        end
      end
    rescue => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end

  def logout
    response = {}
    ActiveRecord::Base.transaction do
      session[:current_user] = nil
    end
    respond_to do |format|
      format.json { render json: response }
    end
  end

  # TODO: This method should be separated in other methods (refresh, commit, destroy, search)
  def refresh
    response = {}
    begin
      ActiveRecord::Base.transaction do

        # Prepare response for requested models
        response = {}

        # Relations to be fetched
        relations = params[:relations]

        if relations
          response[:models] = {}
          resp_relations = response[:relations] = {}

          # TODO: Optimize!
          relations.each do |model_type, model_info|
            model_class = acl_scoped_class(model_info[:railsClass], :read)
            relation_type = model_info[:relationType]
            relation_class = model_info[:railsRelationClass]
            relation_attribute = model_info[:railsRelationAttribute].underscore.to_sym
            resp_relations[model_type] = {} unless resp_relations[model_type]
            resp_relations[model_type][relation_type] = {
              :attribute => model_info[:railsRelationAttribute],
              :models => {}
            } unless resp_relations[model_type][relation_type]

            model_class.where(:id => model_info[:ids]).each do |model|
              relation_result = model.send(relation_attribute)
              next unless relation_result
              response[:models][relation_class.to_s] = [] unless response[:models][relation_class.to_s]
              if relation_result.respond_to?(:map)
                resp_relations[model_type][relation_type][:models][model.id] = relation_result.map do |rm|
                  rm.id
                end
                response[:models][relation_class.to_s].concat(relation_result)
                fill_eager_refresh relation_class, relation_result, response
              else
                resp_relations[model_type][relation_type][:models][model.id] = [relation_result.id]
                response[:models][relation_class.to_s].push(relation_result)
                fill_eager_refresh relation_class, [relation_result], response
              end
            end
          end
        end
      end

      # Models to be fetched
      models = params[:refreshModels]
      if models
        response.merge!(refresh_models(models)) do |key, v1, v2|
          v1.merge!(v2) do |key, v3, v4|
            v3.concat(v4)
          end
        end
      end

    rescue ErrorTransportException => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end

  def find
    response = {}
    begin
      ActiveRecord::Base.transaction do

        # Models to be searched
        models = params[:searchModels]
        if models
          params[:refreshModels] = {} unless params[:refreshModels]
          response[:models] = {} if not response[:models]
          models = [models] if not models.kind_of?(Array)
          page_data = response[:pageData] = {}
          models.each do |model_info|
            rails_class = acl_scoped_class(model_info[:railsClass], :read)
            result = rails_class.rails_store_search(model_info[:searchParams])
            page = model_info[:page].to_i
            page = 1 if page == 0
            limit = model_info[:limit].to_i
            limit_low = 0
            limit_high = result.count
            if limit > 0
              limit_low = (page-1) * limit
              limit_high = limit_low+limit-1
            end
            counter = 0
            pages = 1
            pages = (result.count.to_f / limit.to_f).ceil.to_i if limit > 0
            page_data[model_info[:railsClass]] = {
              :ids => [],
              :pageSize => limit,
              :actualPage => page,
              :pages => pages
            }
            response[:models][model_info[:railsClass]] = []
            result.each do |m|
              page_data[model_info[:railsClass]][:ids].push(m.id)
              if limit == 0 or (limit_low <= counter and counter <= limit_high)
                response[:models][model_info[:railsClass]].push(m)
                counter += 1 unless limit == 0
              end
            end
            fill_eager_refresh model_info[:railsClass], response[:models][model_info[:railsClass]], response
          end
        end

      end

    rescue ErrorTransportException => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end

  def commit
    response = {}
    begin
      ActiveRecord::Base.transaction do

        # First persist models
        models = params[:commitModels]
        if models
          new_models = {}
          set_after_create = []
          models_ids = response[:modelsIds] = {}
          server_models = []
          javascript_classes = {}
          models.each do |key, model_info|
            klass = model_info[:railsClass]
            model_info[:data].each do |model|
              if model['id']
                server_model = acl_scoped_class(klass, :write).find(model['id'])
                raise_error_hash(klass, 'no write permission') unless server_model
              else
                server_model = klass.constantize.new(model)
                server_model.cid = model['cid']
                new_models[model['cid']] = server_model
                models_ids[key.to_sym] = {} unless models_ids[key.to_sym]
                javascript_classes[klass.to_sym] = key
              end

              server_models << server_model

              #server_model.assign_attributes(model)
#              updated = server_model.update_attributes(model)
#              raise_error(server_model) unless updated

              model.each do |attr_key, attr|
                if attr_key.match(/.*_id$/)
                  if attr.to_s().match(/c[[:digit:]]*/)
                    set_after_create.push({
                                              :model => server_model,
                                              :railsClass => klass,
                                              :key => key,
                                              :attr  => attr_key,
                                              :temp_id => attr
                                          })
                  else
                    server_model[attr_key] = attr
                  end
                end
              end
#              saved = server_model.save
#              raise_error(server_model) unless saved
            end
          end

          #save sequence -
          server_models.sort { |a,b| compare_server_models(a, b, set_after_create, new_models) }


          server_models.each do |server_model|
            if server_model.new_record?
              cid = server_model.cid
              server_model.save
              raise_error(server_model) unless server_model.errors.empty?
              key = javascript_classes[server_model.class.name.to_sym]
              #here: problem if server_model class name is not the same as the javascript model class name
              models_ids[key.to_sym][:"#{server_model.cid}"] = server_model.id
              params[:refreshModels] = {} unless params[:refreshModels]
              params[:refreshModels][key] = {
                  :railsClass => server_model.class.name,
                  :ids => []
              } if not params[:refreshModels][key]
              params[:refreshModels][key][:ids].push(server_model.id)

              inverse_deps = get_inverse_dependencies cid, set_after_create

              inverse_deps.each do |dep|
                dep[:model][dep[:attr_name]] = server_model.id
              end
            else
              server_model.save
              raise_error(server_model) unless server_model.errors.empty?
            end




          end

          set_after_create.each do |info|
            params[:refreshModels][info[:key]] = {
                :railsClass => info[:railsClass],
                :ids => []
            } unless params[:refreshModels][info[:key]]
            params[:refreshModels][info[:key]][:ids].push(info[:model].id)
          end


        end

        # Destroy models
        models = params[:destroyModels]
        if models
          models.each do |key, model_info|
            model_info.each do |model|
              if model['id']
                acl_scoped_class(key, :remove).destroy(model['id'])
              end
            end
          end
        end

        # Create Relations
        relations = params[:createRelations]
        if relations
          relations.each do |key, data|
            klass = data[:railsClass]
            data[:models].each do |id, data|
              data.each do |relation, data|
                relation_klass = data[:railsClass]
                new_relations = acl_scoped_class(relation_klass, :read).where(:id => data[:ids])
                model = acl_scoped_class(klass, :write).find(id)
                raise_error_hash(klass, 'no write permission') unless model
                actual_relations = model.send("#{relation}")
                new_relations.each do |relation|
                  actual_relations.push relation unless actual_relations.include?(relation)
                end
              end
            end
          end
        end

        # Destroy Relations
        relations = params[:destroyRelations]
        if relations
          relations.each do |key, data|
            klass = data[:railsClass]
            data[:models].each do |id, data|
              data.each do |relation, data|
                next if data.nil?
                data[:ids] = [] if data[:ids].nil? or not data[:ids].is_a?(Array)
                model = acl_scoped_class(klass, :read).find(id)
                raise_error_hash(klass, 'no read permission') unless model
                relation_array = model.send("#{relation}")
                result_relations = relation_array.reject do |relation_model|
                  data[:ids].include?(relation_model.id)
                end
                model = acl_scoped_class(klass, :write).find(id)
                raise_error_hash(klass, 'no write permission') unless model
                model.send("#{relation}=", result_relations)
              end
            end
          end
        end

        response.merge!(refresh_models(params[:refreshModels])) if params[:refreshModels]
      end

    rescue ErrorTransportException => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response.as_json }
    end
  end

  def upload
    response = {success: true}
    begin
      ActiveRecord::Base.transaction do
        klass = params[:railsClass].constantize
        field = params[:railsAttr]
        f = klass.create()
        data = {field.to_sym => request.request_parameters[:qqfile]}
        data.merge!(params[:modelParams]) if params[:modelParams]
        f.update_attributes(data)
        response[:id] = f.id
      end
    rescue ErrorTransportException => exp
      response = {errors: exp.errors}
    end

    respond_to do |format|
      format.json { render json: response }
    end
  end




  private


  #returns an array this server model depends to be saved (dependencies must be saved before)
  def get_server_model_dependencies a, dependency_info, new_models
    dependencies = []
    dependency_info.each do |info|
      if a == info[:model]
        dependencies << new_models[info[:temp_id]]
      end
    end
    dependencies
  end

  #returns an array of hashes with two props: model and attr_name, of the entities dependent of the one being saved.
  def get_inverse_dependencies cid, dependency_info
    dependencies = []
    dependency_info.each do |info|
      if cid == info[:temp_id]
        dependencies << {:model => info[:model], :attr_name => info[:attr]}
      end
    end
    dependencies
  end

  def compare_server_models a, b, set_after_create, new_models
    a_dependencies =  get_server_model_dependencies a, set_after_create, new_models
    if a_dependencies.include?(b)
      return -1
    end
    b_dependencies = get_server_model_dependencies b, set_after_create, new_models
    if b_dependencies.include?(a)
      return 1
    end
    0
  end

  def raise_error(model)
    errors = {
        :railsClass => model.class.name,
        :model => model,
        :errors => model.errors
    }
    raise ErrorTransportException.new(errors), "Doh!"
  end

  def raise_error_hash(class_name, errors)
    raise ErrorTransportException.new({:railsClass => class_name, :errors => errors})
  end

  def refresh_models models
    response = {
        :models => {},
        :relations => {}
    }
    resp_models = response[:models]
    resp_relations = response[:relations]

    # Retrieve all models and then eager load
    models.each do |key, model_info|
      # TODO: in case model has been erased on server, notify
      ids = model_info[:ids] || []
      model_class = model_info[:railsClass]
      server_models = acl_scoped_class(model_class, :read).where(:id => ids.uniq).all
      models_eager = {:models => {}, :relations => {}}
      fill_eager_refresh model_class, server_models, models_eager
      resp_models[model_info[:railsClass]] = server_models
      resp_models.merge!(models_eager[:models]) do |key, v1, v2|
        v1.concat(v2)
      end
      resp_relations.merge!(models_eager[:relations]) do |key, v1, v2|
        v1.merge!(v2) do |key, v1, v2|
          v1[:models].merge!(v2[:models]) do |key, v1, v2|
            v1.concat(v2)
            v1
          end
        end
      end
    end

    response
  end

  def fill_eager_refresh klass, models, models_eager
    return unless models.length > 0
    model_ids = models.map do |model|
      model.id
    end
    models_eager_ids = {:model_ids => {}, :relations => {}}
    fill_eager_refresh_ids klass, model_ids, models_eager_ids
    models_eager_ids[:model_ids].each do |other_klass, ids|
      models_eager[:models][other_klass] = [] unless models_eager[:models][other_klass]
      models_eager[:models][other_klass].concat(other_klass.constantize.where(:id => ids))
    end
    models_eager[:relations] = {} unless models_eager[:relations]
    models_eager[:relations].merge!(models_eager_ids[:relations]) do |key, v1, v2|
      v1.merge!(v2) do |key, v1, v2|
        v1[:models].merge!(v2[:models]) do |key, v1, v2|
          v1.concat(v2)
          v1
        end
      end
    end
  end

  def fill_eager_refresh_ids klass_name, ids, models_eager
    klass = klass_name.constantize
    return unless (klass.respond_to?(:rails_store_eager) and ids.length > 0)
    klass_scoped = acl_scoped_class(klass_name, :read)
    klass.rails_store_eager.each do |relation|
      relation_reflection = klass.reflect_on_association(relation)
      raise "Invalid relation #{relation} on #{klass}!" unless relation_reflection
      relation_class = relation_reflection.class_name.to_s
      models_eager[:model_ids][relation_class] = [] unless models_eager[:model_ids][relation_class]
      origin_table_name = klass.table_name
      relation_table_name = relation_reflection.klass.table_name
      if origin_table_name == relation_table_name
        relation_table_name = "#{relation.to_s}_#{relation_table_name}"
      end
      query_opts = {}
      query_opts[:order] = relation_reflection.options[:order]
      query_opts[:conditions] = {:id => ids.uniq}
      query_opts[:joins] = relation
      query_opts[:select] = "#{origin_table_name}.id as id, #{relation_table_name}.id as relation_id"
      model_relation_ids = klass_scoped.all(query_opts)
      relation_ids = model_relation_ids.map do |relation_info|
        models_eager[:model_ids][relation_class].push(relation_info.relation_id)
        relation_info.relation_id
      end
      models_eager[:model_ids][relation_class].uniq!
      case relation_reflection.macro
        when :has_and_belongs_to_many, :has_one
          models_eager[:relations] = {} unless models_eager[:relations]
          models_eager[:relations][klass.to_s] = {} unless models_eager[:relations][klass.to_s]
          models_eager[:relations][klass.to_s][relation_class] = {
              :attribute => relation,
              :models => {}
          } unless models_eager[:relations][klass.to_s][relation_class]
          rmodels = models_eager[:relations][klass.to_s][relation_class][:models]
          model_relation_ids.each do |mid|
            rmodels[mid[:id]] = [] unless rmodels[mid[:id]]
            rmodels[mid[:id]].push(mid[:relation_id])
          end
      end
      fill_eager_refresh_ids(relation_class, relation_ids, models_eager)
    end
  end

  def acl_scoped_class class_name, op
    klass = class_name.constantize
    return klass.rails_store_acl_scope(session[:current_user], op) if klass.respond_to?(:rails_store_acl_scope)
    klass
  end

  def sanetize_search_params(params)
    params = params.symbolize_keys
    if params[:joins]
      params[:joins] = [params[:joins]] if not params[:joins].kind_of?(Array)
      params[:joins] = params[:joins].inject([]) do |result, value|
        value = case value
                when String then value.to_sym
                else value
                end
        result.push(value)
      end
    end
    return params
  end
end
