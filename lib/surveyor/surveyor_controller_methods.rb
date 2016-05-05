module Surveyor
  module SurveyorControllerMethods
    def self.included(base)
      base.send :before_filter, :get_current_user, :only => [:new, :create]
      base.send :layout, 'surveyor_default'
    end

    # Actions
    def new
      @surveys = Survey.find(:all)
      @title = "You can take these surveys"
      redirect_to surveyor_index unless surveyor_index == available_surveys_path
    end

    def create
      @survey = Survey.find_by_access_code(params[:survey_code])
      @response_set = ResponseSet.create(:survey => @survey, :user_id => (@current_user.nil? ? @current_user : @current_user.id))
      if (@survey && @response_set)
        flash[:notice] = t('surveyor.survey_started_success')
        redirect_to(edit_my_survey_path(:survey_code => @survey.access_code, :response_set_code  => @response_set.access_code))
      else
        flash[:notice] = t('surveyor.Unable_to_find_that_survey')
        redirect_to surveyor_index
      end
    end

    def show
      @response_set = ResponseSet.find_by_access_code(params[:response_set_code], :include => {:responses => [:question, :answer]})
      if @response_set
        @survey = @response_set.survey
        respond_to do |format|
          format.html #{render :action => :show}
          format.csv {
            send_data(@response_set.to_csv, :type => 'text/csv; charset=utf-8; header=present',:filename => "#{@response_set.updated_at.strftime('%Y-%m-%d')}_#{@response_set.access_code}.csv")
          }
        end
      else
        flash[:notice] = t('surveyor.unable_to_find_your_responses')
        redirect_to surveyor_index
      end
    end

    def edit
      @response_set = ResponseSet.find_by_access_code(params[:response_set_code], :include => {:responses => [:question, :answer]})
      if @response_set
        @survey = Survey.with_sections.find_by_id(@response_set.survey_id)
        @sections = @survey.sections
        if params[:section]
          @section = @sections.with_includes.find(section_id_from(params[:section])) || @sections.with_includes.first
        else
          @section = @sections.with_includes.first
        end
        @dependents = (@response_set.unanswered_dependencies - @section.questions) || []
      else
        flash[:notice] = t('surveyor.unable_to_find_your_responses')
        redirect_to surveyor_index
      end
    end

    def update
      @response_set = ResponseSet.
        find_by_access_code(params[:response_set_code], :include => {:responses => :answer},
                            :lock => true)
      return redirect_with_message(available_surveys_path, :notice,
                                   t('surveyor.unable_to_find_your_responses')) if @response_set.blank?

      question_ids = params[:r].values.map{|r| r["question_id"]}.flatten.uniq
      parameters_sanitized = ResponseSet.reject_or_destroy_blanks(params[:r])
      answer_ids = parameters_sanitized.values.map{|r| r[:id].blank? ? nil : r[:answer_id] }.flatten.compact.uniq.map{|a| a.to_i}
      saved = false

      ActiveRecord::Base.transaction do
        # ensure that all answers for the submitted questions are removed even if there are no new answers

        @response_set.responses.where("question_id" => question_ids).reject{|r| answer_ids.include? r.answer_id}.each{ |r| r.destroy }
        saved = @response_set.update_attributes( { :responses_attributes => parameters_sanitized.reject{|k,v| v.has_key?("_destroy") } })

        if params[:finish]
          @response_set.complete! if saved
          saved &= @response_set.save
        end
      end

      return redirect_with_message(surveyor_finish, :notice,
                                   t('surveyor.completed_survey')) if saved && params[:finish]

      respond_to do |format|
        format.html do
          flash[:notice] = t('surveyor.unable_to_update_survey') unless saved
          redirect_to edit_my_survey_path(:anchor => anchor_from(params[:section]),
                                          :section => section_id_from(params[:section]))
        end

        format.js do
          ids, remove = {}, {}
          parameters_sanitized.each do |k,v|
            ids[k] = @response_set.responses.
              find(:first, :conditions => v).id unless v.has_key?("id")

            remove[k] = v["id"] if v.has_key?("id") && v.has_key?("_destroy")
          end

          render :json => {"ids" => ids, "remove" => remove}.
            merge(@response_set.reload.all_dependencies(question_ids))
        end
      end
    end

    private

    # Filters
    def get_current_user
      @current_user = self.respond_to?(:current_user) ? self.current_user : nil
    end

    # Params: the name of some submit buttons store the section we'd like to go to. for repeater questions, an anchor to the repeater group is also stored
    # e.g. params[:section] = {"1"=>{"question_group_1"=>"<= add row"}}
    def section_id_from(p)
      p.respond_to?(:keys) ? p.keys.first : p
    end

    def anchor_from(p)
      p.respond_to?(:keys) && p[p.keys.first].respond_to?(:keys) ? p[p.keys.first].keys.first : nil
    end

    def surveyor_index
      available_surveys_path
    end
    def surveyor_finish
      available_surveys_path
    end

    def redirect_with_message(path, message_type, message)
      respond_to do |format|
        format.html do
          flash[message_type] = message if !message.blank? and !message_type.blank?
          redirect_to path
        end
        format.js do
          render :text => message, :status => 403
        end
      end
    end
  end
end
