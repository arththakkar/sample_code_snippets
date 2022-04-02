# frozen_string_literal: true

module Organisers
  class EventsController < Organisers::BaseController
    include ApplicationHelper
    include Pagy::Backend

    layout 'organiser'

    before_action :event, includes: :schedules

    read_replica only: %i[dashboard summary]

    def dashboard
      @event_registrations = @event.registrations.includes(:user)
      @tickets_sold = @event_registrations.joins(:persona).group('personas.label').count

      @current_week_registrations = @event_registrations.where('created_at >= ?', 1.week.ago).size
      @last_week_registrations = @event_registrations.where(created_at: (2.weeks.ago..1.week.ago)).size
      @registrations_increase_percent = calc_percentage_increase(@current_week_registrations, @last_week_registrations)

      @registration_price_sum = @event.ticket_sales
      @current_week_ticket_sales = @event_registrations.where('registrations.created_at >= ?', 1.week.ago).sum(:price)
      @last_week_ticket_sales = @event_registrations.where(registrations: { created_at: (2.weeks.ago..1.week.ago) })
                                                    .sum(:price)
      @ticket_sales_increase_percent = calc_percentage_increase(@current_week_ticket_sales, @last_week_ticket_sales)

      @event_part_stage = @event.event_parts.where(event_part_type: :stage).first

      @registrations_by_country = registrations_by_country
    end

    def analytics
    end

    def summary
      all_users = User.joins(:registrations).where(registrations: { event_id: event.id })
      @pagy, @users = pagy(all_users)

      @event_registrations = @event.registrations
      if @event_registrations.size.zero?
        flash[:alert] = 'No summary for this event since no-one registered to it.'
        redirect_to(dashboard_organisers_event_path(event)) && return
      end

      event_likes = Like.where(event: event)
      @likes = event_likes.where(user: @users).group(:user_id).count
      @liked = event_likes.where(liked: @users).group(:liked_id).count
      @matched = event_likes.where(user: @users, matched: true).group(:user_id).count

      @registrations_per_week = @event_registrations.group_by_week(:created_at).count
      @registration_price_sum = @event_registrations.sum(:price)
      @sales_per_day = @event_registrations.group_by_day(:created_at).sum(:price)
      @tickets_sold = @event_registrations.joins(:persona).group('personas.label').count
      @turnout = @event_registrations.where(participated: true).count

      @total_reports_count = @event.reports.size

      @zero_matches_count = all_users.size - event_likes.where(matched: true, user_id: all_users.pluck(:id))
                                                        .distinct.count(:user_id)
      @matches_count = event_likes.where(liked: all_users, matched: true).size

      @registrations_by_country = registrations_by_country

      if @event.organization.analytics?
        @logs_download_link = "#{ENV['ANALYTICS_API_HOST']}/dump/logs/#{event.id}"
      end

      @preview = true if current_admin_user
    end

    def download_connection_summary
      job_params = { event_id: event.id }
      EventConnectionsReportJob.perform_with_progress(current_organiser, current_user, job_params)
      report_enqueued
    end

    def download_event_chat
      job_params = {
        roundtable_id: params[:roundtable_id].to_i,
        backstage_id: params[:backstage_id].to_i,
        stage_id: params[:stage_id].to_i,
        event_id: event.id,
      }.select { |_, value| value.positive? }
      EventChatReportJob.perform_with_progress(current_organiser, current_user, job_params)
      report_enqueued
    end

    def download_participants
      area_parts = params[:area].to_s.split
      segment = area_parts[0].strip || nil
      resource_id = area_parts.size == 2 ? area_parts[1].strip.to_i : nil
      job_params = {
        event_id: event.id,
        with_extra_fields: event.has_registration_fields?,
        segment: segment,
        resource_id: resource_id,
        with_minutes: true,
      }
      EventParticipationReportJob.perform_with_progress(current_organiser, current_user, job_params)
      report_enqueued
    end

    def download_attendee_list
      job_params = {
        event_id: event.id,
        with_extra_fields: false,
        segment: 'All',
        resource_id: nil,
        with_minutes: false,
      }
      EventParticipationReportJob.perform_with_progress(current_organiser, current_user, job_params)
      report_enqueued
    end

    def download_movement_logs
      job_params = { event_id: event.id }
      EventMovementsReportJob.perform_with_progress(current_organiser, current_user, job_params)
      report_enqueued
    end

    def download_counters
      job_params = { event_id: event.id }
      EventCountersReportJob.perform_with_progress(current_organiser, current_user, job_params)
      report_enqueued
    end

    def download_polls
      job_params = { event_id: event.id }
      EventPollsReportJob.perform_with_progress(current_organiser, current_user, job_params)
      report_enqueued
    end

    def stage_summary
      @stage_part = event.event_parts.stage.first
      @backstages = @stage_part.backstages.includes(:stage)
    end

    def sessions_summary
      @recording_generator = Events::ListRecordingsService.new(event)
      sessions = event.event_parts.sessions.first.roundtables.non_private.includes(:opentok_archives)
      @pagy, @sessions = pagy(sessions)
    end

    def edit
      if current_organiser.blank?
        flash[:notice] = 'Create an organization profile to edit events'
        redirect_to new_organization_path
      end
    end

    def publish
      if event.draft?
        if event.time_start.past? || event.time_end.past?
          redirect_to dashboard_organisers_event_path(event), alert: "Start date or End date can not be in past"
        else
          event.live!
          process_post_publish
          redirect_to dashboard_organisers_event_path(event), notice: "Event successfully marked as #{event.status}"
        end
      else
        begin
          event.draft!
          redirect_to dashboard_organisers_event_path(event), alert: "Event successfully marked as #{event.status}"
        rescue ActiveRecord::RecordInvalid => e
          redirect_to dashboard_organisers_event_path(event), notice: "Cannot unpublish - #{e.message}"
        end
      end
    end

    def reception_form
      @host = current_user
    end

    def segments
      @host = current_user
      @event_part_stage = event.event_parts.stage.first
      @event_part_meetings = event.event_parts.networking.first
      @event_part_sessions = event.event_parts.sessions.first
      @event_part_expo = event.event_parts.expo.first
    end

    def stage
      @event_part_stage = event.event_parts.stage.first
      @rtmp_details = @event_part_stage.backstage.rtmp_details.first
    end

    def networking
      @event_part_meetings = event.event_parts.networking.first
    end

    def sponsor_form
      @host = current_user
    end

    def sponsors
    end

    def meetings
      @host = current_user
    end

    def registration
      @host = current_user
    end

    def invitations
      @host = current_user
    end

    def advanced_settings
    end

    def design
      unless current_organiser.custom_branding?
        redirect_back(fallback_location: dashboard_organiser_event_path(@event))
      end
    end

    def text
      unless current_organiser.custom_text?
        redirect_back(fallback_location: dashboard_organiser_event_path(@event))
      end
    end

    def update
      respond_to do |format|
        params[:event][:schedules_attributes] &&= schedule_in_event_timezone

        if event.started? && event.time_start_changed?
          format.html do
            redirect_to edit_organisers_event_path(event),
                        alert: 'Event is already started, can not change start time.'
          end
          format.js do
            render json: { messages: ['Event is already started, can not change start time.'] },
                   status: :unprocessable_entity
          end
        elsif event.update_with_context(event_params, params[:context])
          Events::UpdateEventPartsService.call(event, params[:schedule_name])
          flash.now[:notice] = 'Event was successfully updated.'
          format.html { render params[:context].presence || 'edit' }
          format.js { head :no_content }
        else
          flash.now[:alert] = event.errors.full_messages.join(', ')
          format.html { render params[:context].presence || 'edit' }
          format.js { render json: event.errors, status: :unprocessable_entity }
        end
      end
    end

    def destroy
      if event.valid_for_deletion? && event.destroy
        flash[:notice] = 'Event removed.'
        redirect_to organizations_events_path
      else
        flash[:alert] = 'Oops, something went wrong. Please try again later.'
        redirect_to dashboard_organisers_event_path(event)
      end
    end

    private

    def registrations_by_country
      event.users.joins(:user_extra).group('user_extras.country').count
    end

    def report_enqueued
      redirect_to(dashboard_organisers_event_path(event),
                  notice: 'Your report is in the queue, you will receive an email once it is ready.')
    end

    def event_id_param
      params[:id]
    end

    def process_post_publish
      AnalyticsGateway.track(current_user, 'Publish Event', event)
    end

    def calc_percentage_increase(current, before)
      current != 0 ? (current - before) / current.to_f * 100 : 0
    end

    def schedule_in_event_timezone
      ::Events::ScheduleTimezoneService.new(event).schedule_in_event_tz(params[:event][:schedules_attributes])
    end

    def locale_params(locale)
      if locale[:custom_text_json] == ''
        locale[:custom_text_json] = nil
        return locale
      end
      custom = JSON.parse(locale[:custom_text_json], symbolize_names: true)
      custom&.keys.to_a.each { |group| custom.delete(group) if custom[group].keys.blank? }
      locale[:custom_text_json] = nil if custom&.keys.blank?
      locale
    end

    def event_params
      time_start = params[:event][:time_start]
      time_end = params[:event][:time_end]
      timezone = params[:event][:timezone] || event.timezone
      if time_start.present?
        tmp_start = cast_time_in_timezone(time_start.to_datetime, timezone)
        params[:event][:time_start] = tmp_start
      end
      if time_end.present?
        tmp_end = cast_time_in_timezone(time_end.to_datetime, timezone)
        params[:event][:time_end] = tmp_end
      end
      if params[:event][:locale_attributes].present?
        tmp_locale = params[:event][:locale_attributes]
        params[:event][:locale_attributes] = locale_params(tmp_locale)
      end

      params.require(:event).permit(
        :name, :location, :description, :password, :currency,
        :time_start, :picture, :min_timer_length, :slug,
        :short_description, :private, :location_preference, :youtube_link, :hide_people_area,
        :capacity, :max_distance, :is_private, :webinar_link, :style,
        :time_end, :timer_length, :max_age, :orientation, :video, :message, :attendees_visiblity, :timezone,
        :price, :image, :registration_status, :event_type, :show_emails, :gdpr_text,
        :strict_schedule, :v2, :suppress_emails, :network_type, :logo, :color, :theme, :analytics_code,
        :embed_ticket_success_url, :embed_ticket_error_url,
        personas_attributes: %i[id label price description count discount status matched_id _destroy],
        sponsors_attributes: %i[
          id name email logo about offering calendar_link matched_id _destroy youtube instagram twitter facebook
        ],
        locale_attributes: %i[id custom_text_json],
        extra_attributes: %i[id invite_to_video_call],
        schedules_attributes: %i[id time_start time_end]
      )
    end
  end
end
