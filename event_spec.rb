# frozen_string_literal: true

describe Event, type: :model do
  subject { create(:event) }

  let(:event_registration) { build(:event_registration) }

  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }

    it { is_expected.to validate_presence_of(:location) }
    it { is_expected.to validate_presence_of(:location_preference) }
    it { is_expected.to validate_presence_of(:currency) }
    it { is_expected.to validate_presence_of(:time_start) }
    it { is_expected.to validate_presence_of(:time_end) }
    it { is_expected.to validate_presence_of(:timezone) }

    it 'is not valid when short_description is too long' do
      subject.short_description = 'h' * 150
      expect(subject).not_to be_valid
    end

    it 'is valid reception with context' do
      subject.message = 'R' * 35
      expect(subject).to be_valid(:reception_form)
      expect(subject.errors.size).to be(0)
    end

    it 'is not valid without a message with context' do
      subject.message = nil
      expect(subject).not_to be_valid(:reception_form)
      expect(subject.errors.size).to be(1)
    end

    it 'is not valid when a message is too short' do
      subject.message = 'h' * 20
      expect(subject).not_to be_valid(:reception_form)
      expect(subject.errors.size).to be(1)
    end

    it 'is valid registration form for with context' do
      expect(event_registration).to be_valid(:registration)
      expect(event_registration.errors.size).to eq(0)
    end

    it 'is not valid without a description registration form for with context' do
      event_registration.description = nil
      expect(event_registration).not_to be_valid(:registration)
      expect(event_registration.errors.size).to be(1)
    end

    it 'is not valid when a description is too short' do
      event_registration.description = 'h' * 20
      expect(event_registration).not_to be_valid(:registration)
      expect(event_registration.errors.size).to be(1)
    end
  end

  describe 'associations' do
    it { is_expected.to have_many(:registrations).dependent(:destroy) }
    it { is_expected.to have_many(:waitlisted_registrations).class_name('Registration') }
    it { is_expected.to have_many(:users).through(:registrations) }
    it { is_expected.to have_many(:reports).dependent(:destroy) }
    it { is_expected.to have_many(:passes).dependent(:destroy) }
    it { is_expected.to have_many(:passed_users).through(:passes) }
    it { is_expected.to have_many(:personas).dependent(:destroy) }
    it { is_expected.to have_many(:waitlisted_users).through(:waitlisted_registrations) }
    it { is_expected.to have_many(:discounts).dependent(:destroy) }
    it { is_expected.to have_many(:invitations).dependent(:destroy) }
    it { is_expected.to have_many(:duplication_job_details).dependent(:destroy) }
    it { is_expected.to have_many(:speakers).dependent(:destroy).class_name('SpeakerUser') }
    it { is_expected.to have_many(:networking_availables).dependent(:destroy) }
    it { is_expected.to have_many(:chat_bans).dependent(:destroy) }
    it { is_expected.to have_many(:surveys).dependent(:destroy) }
    it { is_expected.to have_many(:event_affiliates).dependent(:destroy) }
    it { is_expected.to have_many(:likes).dependent(:destroy) }
    it { is_expected.to have_many(:vendors).dependent(:destroy) }
    it { is_expected.to have_many(:messages).dependent(:destroy) }
    it { is_expected.to have_many(:event_parts).dependent(:destroy).inverse_of(:event) }
    it { is_expected.to have_many(:sponsors).dependent(:destroy) }
    it { is_expected.to have_many(:schedules).dependent(:destroy) }
    it { is_expected.to have_many(:email_templates).dependent(:destroy) }
    it { is_expected.to have_many(:mux_recordings).dependent(:destroy) }
    it { is_expected.to have_many(:session_recordings).dependent(:destroy) }
    it { is_expected.to have_many(:event_polls).dependent(:destroy) }
    it { is_expected.to have_many(:roundtables).dependent(:destroy) }
    it { is_expected.to have_many(:registration_fields).dependent(:destroy) }
    it { is_expected.to have_many(:backstages).dependent(:destroy) }
    it { is_expected.to have_one(:backstage).dependent(:destroy) }
  end

  describe 'callbacks' do
    describe 'normalize_slug before_save callback' do
      let(:event) { create(:event, slug: 'some slug') }
      let(:invalid_slug) { 'https://some.slug' }

      it 'normalize slug before creating' do
        expect(event.slug).to eq('some-slug')
      end

      it 'normalize slug before updating' do
        expect { event.update(slug: invalid_slug) }
          .to change(event, :slug).from('some-slug').to('https-some-slug')
      end

      context 'when setting not unique slug' do
        let(:existing_slug) { 'my-slug' }
        let(:invalid_event) { build(:event, slug: 'my slug') }

        before do
          create(:event, slug: existing_slug)
        end

        it 'does not allow saving' do
          expect(invalid_event.valid?).to eq(false)
          expect(invalid_event.errors[:slug]).to eq(['has already been taken'])
        end
      end

      context 'when creating events with the same name' do
        let(:event_name) { 'my event name' }
        let(:event_1) { create(:event, name: event_name) }
        let(:event_2) { create(:event, name: event_name) }

        it 'sets unique slug' do
          expected_slug = 'my-event-name'

          expect(event_1.slug).to eq(expected_slug)
          expect(event_2.slug).to include(expected_slug)
          expect(event_1.slug).not_to eq(event_2.slug)
        end
      end
    end
  end

  describe '.upcoming' do
    let(:non_upcoming_events) { create_list(:non_upcoming_event, 2) }
    let!(:upcoming_event) { create(:upcoming_event) }

    it 'returns only upcoming events' do
      expect(described_class.upcoming.first).to eq(upcoming_event)
    end

    it 'does not return non upcoming events' do
      expect(described_class.upcoming).not_to include(non_upcoming_events)
    end
  end

  describe '.finished' do
    let(:unfinished_events) { create_list(:unfinished_event, 2) }
    let!(:finished_event) { create(:finished_event) }

    it 'returns only finished events' do
      expect(described_class.finished.first).to eq(finished_event)
    end

    it 'does not return non finished events' do
      expect(described_class.finished).not_to include(unfinished_events)
    end
  end

  describe '.search' do
    let!(:sought_event) { create(:event) }

    before { create_list(:event, 10) }

    context 'when there is a search term' do
      it 'returns sought_event when searched by name' do
        expect(described_class.search(sought_event.name)).to include(sought_event)
      end

      it 'returns sought_event when searched by location' do
        expect(described_class.search(sought_event.location)).to include(sought_event)
      end
    end

    context 'when there is no search term' do
      it 'returns all events' do
        expect(described_class.search('').count).to eq(11)
      end

      it 'returns all ordered by time_start' do
        expect(described_class.search('').first).to eq(sought_event)
      end
    end
  end

  describe '.user_attending?' do
    let(:event) { create(:event_with_registrations) }

    it 'returns true if user is attending' do
      user = event.users.first

      expect(event).to be_user_attending(user)
    end

    it 'returns false if user is not attending' do
      user = build(:user)

      expect(event).not_to be_user_attending(user)
    end
  end

  describe '.register_user' do
    let(:event) { create(:event_with_personas, personas_count: 1) }
    let(:user) { create(:complete_user) }
    let(:price) { 10 }
    let(:charge_id) { 'charged' }
    let(:status) { 'done' }
    let(:persona_id) { event.personas.first.id }

    it 'adds a user to the event' do
      expect { event.register_user(user, price, charge_id, persona_id, status) }
        .to change { event.users.count }.from(0).to(1)
    end

    it 'adds a registration to the event' do
      expect { event.register_user(user, price, charge_id, persona_id, status) }
        .to change { event.registrations.count }.from(0).to(1)
    end
  end

  describe '.unregister_user' do
    let(:event) { create(:event_with_registrations, registrations_count: 1) }
    let(:user) { event.users.first }

    it 'removes a user to the event' do
      expect { event.unregister_user(user) }.to change { event.users.count }.from(1).to(0)
    end

    it 'removes a registration to the event' do
      expect { event.unregister_user(user) }.to change { event.registrations.count }.from(1).to(0)
    end
  end

  describe '.event' do
    let(:event) { create(:event_with_registrations, registrations_count: 10) }

    it 'returns age of users' do
      expected = event.users.average(:age).to_f

      expect(event.average_user_age).to eq(expected)
    end
  end

  describe '.has_event_ended?' do
    let(:event) { create(:event) }

    it 'returns true if event has ended' do
      event.time_end = 1.week.ago
      expect(event).to have_event_ended
    end

    it 'returns false if event has ended' do
      event.time_end = 1.week.from_now
      expect(event).not_to have_event_ended
    end
  end

  describe '.starting_now?' do
    let(:event) { create(:event) }

    it 'returns true if event is 5minutes from starting and has not ended' do
      event.time_start = 5.minutes.from_now
      event.time_end = 10.minutes.from_now

      expect(event).to be_starting_now
    end

    it 'returns false if event is more than 5minutes from starting' do
      event.time_start = 6.minutes.from_now
      expect(event).not_to be_starting_now
    end

    it 'returns false if event has ended' do
      event.time_end = 1.minute.ago
      expect(event).not_to be_starting_now
    end
  end

  describe '.early_bird_period?' do
    let(:event) { create(:event) }

    it 'returns true if event is 10 days or more from starting' do
      event.time_start = 11.days.from_now
      expect(event).to be_early_bird_period
    end

    it 'returns false if event is less than 10 days from starting' do
      event.time_start = 10.days.from_now
      expect(event).not_to be_early_bird_period
    end
  end

  describe 'schedules_validations' do
    let(:event) { create(:event) }
    let(:session_part) { create(:event_part, event_part_type: 'sessions', event: event) }

    setup do
      create(:schedule, name: 'Fun time with session', event_part: session_part, event: event,
                        time_start: event.time_start + 1.hour, time_end: event.time_start + 3.hours)
    end

    it 'fails changing the time of the event' do
      event.time_start += event.time_start + 5.hours
      expect(event).not_to be_valid
    end
  end

  describe '#deeply_valid?' do
    let(:event) { create(:event) }

    context 'when all associations have valid records' do
      before do
        create(:event_part, event_part_type: 'sessions', event: event)
      end

      it 'is valid' do
        expect(event).to be_deeply_valid
      end
    end

    context 'with invalid association included' do
      it 'raises error' do
        expect do
          event.be_deeply_valid(only: %i[event_parts unknown])
        end.to raise_error(NoMethodError)
      end
    end

    context 'when some associations have invalid records' do
      before do
        session = create(:event_part, event_part_type: 'sessions', event: event)

        roundtable = build(:roundtable, event: event, event_part: session, description: nil)
        roundtable.save(validate: false)
      end

      context 'when considering all' do
        it 'is invalid' do
          expect(event).not_to be_deeply_valid
        end
      end

      context 'when considering a subset' do
        it 'is invalid' do
          expect(event).to be_deeply_valid(only: [:event_parts])
          expect(event).not_to be_deeply_valid(only: %i[event_parts roundtables])
        end
      end
    end
  end

  describe '.has_registration_fields?' do
    let(:registration_field) { build(:registration_field) }
    let(:event) { create(:event) }

    it 'returns false if event does not have a registration field' do
      expect(event.has_registration_fields?).to be false
    end

    it 'returns true if the event has a registration field' do
      event.registration_fields << registration_field
      expect(event.has_registration_fields?).to be true
    end
  end

  describe 'theme' do
    let(:event) { create(:event) }

    it 'is not valid when the theme is not JSON' do
      event.theme = 'not JSON'
      expect(event).not_to be_valid(:theme)
      expect(event.errors.size).to be(1)
    end

    it 'is valid when the theme is JSON' do
      event.theme = '{ "colorPrimary400": "#000" }'
      expect(event).to be_valid(:theme)
      expect(event.errors.size).to be(0)
    end
  end
end
