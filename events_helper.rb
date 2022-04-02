# frozen_string_literal: true

module EventsHelper # rubocop:disable Metrics/ModuleLength
  def event_picture(event:, size:, css_class: nil, style: nil)
    if %r{^(image|(x-)?application)/(gif)$}.match?(event.picture_content_type)
      height = nil
      width = nil
      case size
      when :thumb
        height = 60
        width = 60
      when :medium
        height = 200
        width = 200
      when :large
        height = 800
        width = 800
      end
      image_tag(event.picture(:original),
                { height: height, width: width, class: css_class, style: style, alt: 'Event picture' }.compact)
    else
      image_tag(event.picture(size), { class: css_class, style: style, alt: 'Event picture' }.compact)
    end
  end

  def event_id
    params[:id]
  end

  # FIXME: to check if we can scope `events` so that we don't
  #        accidentally load an event belonging to someone else
  def set_event
    @event = Event.friendly.find(event_id)
    if current_user.nil?
      session[:buying_event] = event_path(@event)
      session[:event_id] = @event.id
    else
      session[:buying_event] = nil
      session[:event_id] = nil
    end
    gon.push(
      event_id: @event.id,
      is_organiser: current_user.present? && current_user.event_organiser?(@event),
    )
  end

  def reception_url(event)
    event = Event.find(event) if event.is_a? Integer
    "#{inside_event_route(event)}/reception"
  end

  def backstage_url(event, backstage = nil)
    backstage ||= event.backstage
    "#{inside_event_route(event)}/backstage/#{backstage.uuid}"
  end

  def roundtable_url(event, roundtable)
    event = Event.find(event) if event.is_a? Integer
    roundtable = event.roundtables.find(roundtable) if roundtable.is_a? Integer
    "#{inside_event_route(event)}/sessions/#{roundtable.uuid}"
  end

  def expo_url(event, vendor)
    event = Event.find(event) if event.is_a? Integer
    vendor = event.vendors.find(vendor) if vendor.is_a? Integer
    "#{inside_event_route(event)}/expo/#{vendor.id}"
  end

  def event_error_message(field)
    @event.errors[field].join(', ') if @event.errors.any?
  end

  def persona_error_message(field)
    @persona.errors[field].join(', ') if @persona.errors.any?
  end

  def coupon_error_message(field)
    @coupon.errors[field].join(', ') if @coupon.errors.any?
  end

  def event_price_label(event)
    return '' if (visible_personas_count = event.personas.visible.count).zero?

    symbol = event.decorate.currency_symbol

    label =
      if event.max_price == 0
        '<strong>Free</strong>'
      elsif visible_personas_count == 1 || event.min_price == event.max_price
        "<strong>#{symbol}#{format('%<number>.2f', number: event.max_price)}</strong>"
      else
        "From
          <strong>#{symbol}#{format('%<number>.2f', number: event.min_price)}</strong>
          to
          <strong>#{symbol}#{format('%<number>.2f', number: event.max_price)}</strong>"
      end

    sanitize(label)
  end

  def event_dates_label(event)
    start_date_format = '%b %e, %l:%M%p'
    end_date_format = '%b %e, %l:%M%p'

    <<~LABEL
      <strong>#{local_time(event.time_start, start_date_format)}</strong>
      to
      <strong>#{local_time(event.time_end, end_date_format)}</strong>
      #{local_time(event.time_end, '%Z')}
    LABEL
  end

  def event_nav_current_indicator(match_path)
    if %r{backstages/.*/edit}.match?(request.path) && match_path == 'backstages'
      'active-event-nav'
    elsif request.path.split('/').last == match_path
      'active-event-nav'
    end
  end

  def mobile_event_nav_current_indicator(match_path)
    'active' if request.path.include? match_path
  end

  def casual_live_part
    event_parts = @event.event_parts
    if request.path.include?('stage') || request.path.include?('backstage') || request.path.include?('refresh_video')
      @live_part = event_parts.where(event_part_type: :stage).first
    end
    @live_part = event_parts.first if request.path.include? 'reception'
    @live_part = event_parts.first if request.path.include? 'expo'
    @live_part = event_parts.where(event_part_type: :networking).first if request.path.include? 'networking'
    @live_part = event_parts.where(event_part_type: :sessions).first if request.path.include? 'sessions'
  end

  def min_date_start_time(event)
    event.started? || event.time_start.past? ? true : nil
  end

  def min_date_end_time(event)
    event.event_finished? || event.time_end.past? ? true : nil
  end

  private

  def inside_event_route(event)
    "#{request.protocol}#{ENV['HOPIN_WEB_URL']}/events/#{event.slug}"
  end
end
