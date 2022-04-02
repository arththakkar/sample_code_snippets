# frozen_string_literal: true

class Event < ApplicationRecord
  include Cacheable
  extend FriendlyId
  include MatchHelper
  include XssHelper
  include CreateMessageMixin
  include RedisCounters::EventRegistrationsCallbacks::Event
  include MessagesAssociationsMixin
  include CustomAttachmentValidations

  second_level_cache expires_in: 1.hour
  observe_columns_for_cache :slug, :id, :status
  has_paper_trail
  friendly_id :name, use: :slugged

  # Ahoy stuff
  visitable

  REGISTRATIONS_MAP = { 'open' => 'done', 'waitlisting' => 'waitlisted' }.freeze

  URL_REGEX = %r{https?://\S+}.freeze

  enum status: { draft: 0, live: 1 }
  enum attendees_visiblity: { show_all: 0, show_list: 2, show_none: 1 }
  enum location_preference: { random: 0, nearest: 1 }
  enum registration_status: { open: 0, is_waitlisting: 1, invite_only: 2 }
  enum event_type: { public_event: 0, private_event: 1, hidden_event: 2 }

  belongs_to :organization, foreign_key: :organiser_id
  has_many :duplication_job_details, dependent: :destroy
  has_many :registrations, -> { where(status: :done, refunded: false) }, dependent: :destroy
  has_many :all_registrations, -> { where(status: :done) }, class_name: 'Registration'
  has_many :waitlisted_registrations, -> { where(status: :waitlisted, refunded: false) }, class_name: 'Registration'
  has_many :users, through: :registrations
  has_many :reports, dependent: :destroy
  has_many :passes, dependent: :destroy
  has_many :passed_users, through: :passes, source: :passed
  has_many :speakers, class_name: 'SpeakerUser', dependent: :destroy
  has_many :networking_availables, dependent: :destroy
  # TODO: Remove redundant :inverse_of opt. I think rails recognizes the bidirectional association
  has_many :personas, inverse_of: :event, dependent: :destroy
  accepts_nested_attributes_for :personas, reject_if: :all_blank, allow_destroy: true
  has_many :waitlisted_users, through: :waitlisted_registrations, source: :user
  has_many :chat_bans, dependent: :destroy
  has_many :surveys, dependent: :destroy
  has_many :discounts, dependent: :destroy
  has_many :event_affiliates, dependent: :destroy
  has_many :likes, dependent: :destroy
  has_many :invitations, dependent: :destroy, as: :invitable
  has_many :vendors, dependent: :destroy
  has_many :event_parts, dependent: :destroy, inverse_of: :event
  has_many :event_polls, dependent: :destroy
  has_many :sponsors, dependent: :destroy
  has_many :schedules, -> { order('schedules.time_start ASC') }, dependent: :destroy, inverse_of: :event
  accepts_nested_attributes_for :schedules, allow_destroy: true
  has_one :backstage, -> { where(is_primary: true) }, dependent: :destroy
  has_many :backstages, dependent: :destroy
  has_many :email_templates, dependent: :destroy
  has_many :mux_recordings, dependent: :destroy
  has_many :session_recordings, dependent: :destroy
  has_many :roundtables, dependent: :destroy
  has_many :transactional_emails, dependent: :destroy
  has_one :locale, dependent: :destroy, inverse_of: :event, class_name: '::EventLocale'
  has_one :extra, dependent: :destroy, inverse_of: :event, class_name: '::EventExtra'
  accepts_nested_attributes_for :extra
  has_many :registration_fields, -> { order('created_at ASC') }, dependent: :destroy
  # conversations_events has a ON DELETE CASCADE option on a FK reference, so we
  # don't need one in ruby and in here it wouldn't work anyway because AR
  # doesn't support compound primary keys
  has_many :conversations_events # rubocop:disable Rails/HasManyOrHasOneDependent
  has_many :conversations, through: :conversations_events
  has_many :tags, dependent: :destroy

  accepts_nested_attributes_for :locale
  accepts_nested_attributes_for :sponsors, allow_destroy: true, reject_if: proc { |att| att['name'].blank? }

  has_attached_file(
    :picture, styles: { thumb: '60x60#', large: '800x800>', medium: '200x200>' },
              default_url: Rails.configuration.x.default_images.events_default_image_url
  )
  has_attached_file(
    :logo, styles: { thumb: '152x152#' },
           default_url: Rails.configuration.x.default_images.events_default_image_url
  )

  has_attached_file :video
  validates_attachment_content_type :video, content_type: %r{\Avideo/.*\Z}
  validates_attachment_content_type :picture, content_type: %r{\Aimage/.*\Z}, on: :registration
  validates_attachment_size_and_format :picture, less_than: 3.megabytes

  validates :slug, uniqueness: true
  validates :name, :location, :location_preference, :currency, :time_start, :time_end, :timezone, presence: true
  validates :password, presence: { if: proc { |e| e.private_event? } }
  validates :short_description, length: { maximum: 120,
                                          too_long: '%{count} characters is the maximum allowed' }
  validates :message, presence: true, on: :reception_form
  validates :message, allow_blank: true, length: { minimum: 30 }, on: :reception_form
  validates :description, presence: true, on: :registration
  validates :description, allow_blank: true, length: { minimum: 30 }, on: :registration
  validates :color, format: { with: /\A#?(?:[A-F0-9]{3}){1,2}\z/i }, allow_blank: true
  validate :validate_theme
  validate :valid_date_range_required
  validate :validate_max_event_length
  validates_associated :schedules
  validates :embed_ticket_success_url, format: { with: URL_REGEX, message: 'format is invalid' }, allow_blank: true
  validates :embed_ticket_error_url, format: { with: URL_REGEX, message: 'format is invalid' }, allow_blank: true
  validate :validate_status, on: :publish

  scope :upcoming, -> { live.where('time_end > ?', Time.zone.now) }
  scope :finished, -> { live.where('time_end < ?', Time.zone.now) }
  scope :ongoing, -> { live.where('time_end > ? AND time_start < ?', Time.zone.now, Time.zone.now) }

  before_validation :normalize_slug, if: :slug_changed?
  before_save :escape_message, if: :message_changed?
  before_save :escape_description, :description_changed?
  after_save :track_time_end_changed, if: :saved_change_to_time_end
  after_update :notify_start_time_change, if: :saved_change_to_time_start
  after_create :ensure_extra
  after_create :ensure_locale
  before_update :reschedule_emails, if: :suppress_emails_changed?

  def validate_status
    errors.add(:status, 'Cannot unpublish event with registrations') if draft? && registrations.any?
  end

  def ticket_sales
    registrations.sum(:price).round(2)
  end

  # Returns the fees that Stripe charges, which is 2.9% + $0.30/transaction.
  def merchant_fees
    (registrations.sum(:price) * 0.029 + registrations.where.not(price: 0).count * 0.30).round(2)
  end

  def hopin_fees
    (registrations.sum(:price) * (1 - organization.commission)).round(2)
  end

  def net_sales
    (ticket_sales - merchant_fees - hopin_fees).round(2)
  end

  def using_hopin_studio?
    event_parts.stage&.first&.stream_provider == 'hopin'
  end

  def max_networking_search_time
    # TODO: - make this user configurable
    event_parts.networking.first&.timer_length.to_i * 1.3
  end

  def registration_count
    registrations.count
  end

  def role_for(user)
    organization.users.where(id: user.id).exists? ? 'organiser' : 'attendee'
  end

  def notify_start_time_change
    TimeStartChangedJob.perform_later(id) unless suppress_emails
  end

  def unscheduled_event_parts
    event_parts.select do |event_part|
      event_part.schedules.empty?
    end
  end

  def time_start_local
    time_start.to_datetime.in_time_zone(timezone)
  end

  def time_end_local
    time_end.to_datetime.in_time_zone(timezone)
  end

  def free
    price.eql?('0')
  end

  def started?
    live? && Time.zone.now > time_start
  end

  def tickets_count(persona_id)
    registrations.where(persona_id: persona_id).count
  end

  def v2
    true
  end

  def valid_date_range_required
    if time_start.nil?
      errors.add(:time_start, 'must be selected')
    elsif time_end.nil?
      errors.add(:time_end, 'must be selected')
    elsif time_start >= time_end
      errors.add(:time_end, 'must be later than time start')
    end
  end

  # Validates that the event is not longer than the maximum event length
  # that is set for the Organization on its CurrentPaymentPlan.
  def validate_max_event_length
    if total_time > organization.max_event_length_hours * 3600
      errors.add(:event, "cannot be longer than #{organization.max_event_length_hours}")
    end
  end

  def self.search(term)
    if term
      where("lower(name || ' ' || location) LIKE ?", "%#{term.downcase}%")
    else
      order('time_start ASC')
    end
  end

  def event_finished?
    Time.zone.now > time_end
  rescue StandardError
    false
  end

  def any_active_discount?
    discounts.active.count > 0
  end

  def meetings_only?
    event_parts.networking.present? && event_parts.stage.blank?
  end

  def conference_only?
    event_parts.stage.present? && event_parts.networking.blank?
  end

  def no_parts?
    event_parts.stage.blank? && event_parts.networking.blank?
  end

  def is_not_complete?
    create_event_percentage > 90
  end

  def create_event_percentage
    steps = if meetings_only?
              %i[has_registration_area? has_reception_area? has_tickets?]
            elsif conference_only?
              %i[has_registration_area? has_reception_area? has_tickets?]
            elsif no_parts?
              %i[has_registration_area? has_reception_area? has_tickets?]
            else
              %i[has_registration_area? has_reception_area? has_tickets?]
            end
    complete = steps.select { |step| send(step) }
    100 - (complete.length / steps.length.to_f * 100)
  end

  def no_meetings_area?
    timer_length.blank?
  end

  def live_schedule
    schedules.live.first
  end

  def live_part
    live_schedule.event_part if live_schedule.present?
  end

  def next_schedule
    schedules.upcoming.first
  end

  def next_part
    next_schedule.event_part if next_schedule.present?
  end

  def casual_live_part(last_url_token)
    unless last_url_token.nil?
      case last_url_token
      when 'stage'
        event_parts.where(event_part_type: :stage).first
      when 'reception'
        event_parts.first
      when 'expo'
        event_parts.first
      when 'networking'
        event_parts.where(event_part_type: :networking).first
      when 'sessions'
        event_parts.where(event_part_type: :sessions).first
      when 'backstage'
        event_parts.where(event_part_type: :stage).first
      end
    end
  end

  def live_or_next_or_casual_part(last_url_token)
    live_or_next_part || casual_live_part(last_url_token)
  end

  def no_conference_area?
    youtube_link.blank?
  end

  def has_registration_area?
    description.nil? || picture(:original).nil?
  end

  def has_tickets?
    personas.count < 1
  end

  def has_reception_area?
    message.nil?
  end

  def has_conference_area?
    event_parts.stage.present?
  end

  def has_meetings_area?
    event_parts.networking.present?
  end

  def has_roundtables_area?
    event_parts.sessions.present?
  end

  def session_area
    event_parts.sessions.first
  end

  def has_expo_area?
    event_parts.expo.present?
  end

  def expo_area
    event_parts.expo.first
  end

  def total_time
    return 0 if time_start.nil? || time_end.nil?

    time_end - time_start
  end

  def active_discounts
    discounts.active
  end

  def discounted_price
    total_discount = active_discounts.map { |discount| discount.value * price.to_f * 0.01 }.sum
    price.to_f - total_discount
  end

  def localize_params(params)
    timezone_object = ActiveSupport::TimeZone.new(timezone)
    params[:time_start] = timezone_object.parse(params[:time_start]) if params[:time_start]
    params[:time_end] = timezone_object.parse(params[:time_end]) if params[:time_end]
    params
  end

  def user_attending?(user)
    return false if user.nil?

    users.exists? id: user.id
  end

  def user_waitlisted?(user)
    waitlisted_users.exists? id: user.id
  end

  def unregister_user(user)
    users.destroy user
  end

  def average_user_age
    users.average(:age).to_f
  end

  def has_event_ended?
    time_end <= Time.zone.now
  end

  def starting_now?
    Time.zone.now.between?(time_start - 5.minutes, time_end)
  end

  def early_bird_period?
    Time.zone.now < (time_start - 10.days)
  end

  def register_user(user, price, charge_id, persona_id, status, extra_fields = {})
    registrations.create(user: user, price: price, charge_id: charge_id, persona_id: persona_id, status: status,
                         extra_fields: extra_fields)
    # users << user
  end

  # rubocop:disable Metrics/ParameterLists
  def register_user_with_affiliate(user, price, charge_id, persona_id, status, event_affiliate_id, extra_fields = {})
    registrations.create(user: user, price: price, charge_id: charge_id, persona_id: persona_id, status: status,
                         event_affiliate_id: event_affiliate_id, extra_fields: extra_fields)
    # users << user
  end
  # rubocop:enable Metrics/ParameterLists

  def has_meeting?
    event_parts.exists?(event_part_type: :networking)
  end

  def has_conference?
    event_parts.exists?(event_part_type: :stage)
  end

  def has_registration_fields?
    registration_fields.present?
  end

  def organization_logo
    organization.picture(:original)
  end

  def valid_for_deletion?
    registrations.count <= 0
  end

  def password_protected?
    private_event? && password.present?
  end

  def min_price
    personas.visible.minimum(:price) || 0
  end

  def max_price
    personas.visible.maximum(:price) || 0
  end

  def deeply_valid?(only: [])
    associations = Event.reflect_on_all_associations.map(&:name)

    subset = Array(only)
    associated = subset.any? ? subset : associations

    associated.each do |association|
      relation = Array(send(association))
      relation.each do |record|
        unless record.valid?
          errors.add(association, "##{record.id} #{record.errors.full_messages}")
        end
      end
    end
    errors.empty?
  end

  def messages_table_name
    'event_messages'
  end

  private

  def escape_message
    self.message = escape_rich_text_html(message)
  end

  def escape_description
    self.description = escape_rich_text_html(description)
  end

  def normalize_slug
    return if slug.blank?

    self.slug = slug.parameterize
  end

  def track_time_end_changed
    registrations.each do |reg|
      AnalyticsGateway.track(reg.user, 'Time End Changed', self)
    end
  end

  def reschedule_emails
    return unless suppress_emails_change == [true, false]
    return if time_end <= Time.zone.now

    RescheduleEventEmailsJob.perform_later(id)
  end

  def ensure_extra
    create_extra if extra.nil?
  end

  def ensure_locale
    create_locale if locale.nil?
  end

  def validate_theme
    JSON.parse(theme) if theme.present?
  rescue StandardError
    errors.add(:theme, 'must be valid JSON')
  end
end
