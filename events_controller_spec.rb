# frozen_string_literal: true

describe Organisers::EventsController, mocks: [:opentok] do
  let(:organiser_user) { create(:user, :with_organisers) }
  let(:organization) { organiser_user.organizations.active.last }
  let!(:event) do
    create(:event, :with_stage, status: 'live', organization: organization, timezone: timezone, time_start: time_start)
  end
  let(:persona) { create(:persona, event: event) }
  let(:timezone) { 'UTC' }
  let(:time_start) { Time.zone.now }

  before do
    Backstage.skip_callback(:create, :before, :build_mux_broadcasts)
    Backstage.skip_callback(:create, :after, :create_roundtable_object)
  end

  after do
    Backstage.set_callback(:create, :before, :build_mux_broadcasts)
    Backstage.set_callback(:create, :after, :create_roundtable_object)
  end

  describe 'GET #download_participants' do
    before do
      sign_in(organiser_user)
      stub_request(:post, %r{/internal/participation}).to_return(
        status: 200, body: '{"1": 1}',
      )
    end

    it 'can enqueue job and redirect to dashboard' do
      get download_participants_organisers_event_path(event), params: { area: 'All' }
      expect(response).to redirect_to(dashboard_organisers_event_path(event))
      expect(EventParticipationReportJob).to have_been_enqueued
    end
  end

  describe 'GET #download_attendee_list' do
    before do
      sign_in(organiser_user)
      stub_request(:post, %r{/internal/participation}).to_return(
        status: 200, body: '{"1": 1}',
      )
    end

    it 'can enqueue job and redirect to dashboard' do
      get download_attendee_list_organisers_event_path(event)
      expect(response).to redirect_to(dashboard_organisers_event_path(event))
      expect(EventParticipationReportJob).to have_been_enqueued
    end
  end

  describe 'GET #download_event_chat', mocks: [:opentok] do
    before { sign_in(organiser_user) }

    let(:params) { { event_id: event.id } }

    describe 'event chat history' do
      it 'queues a job to produce event chat history' do
        get download_event_chat_organisers_event_path(event), params: params
        expect(response).to redirect_to(dashboard_organisers_event_path(event))
        job_id = OrganiserJob.last.id
        expect(EventChatReportJob).to have_been_enqueued.with(job_id, { event_id: event.id })
      end
    end

    describe 'roundtable chat history' do
      let(:roundtable) { create(:roundtable, event: event) }
      let(:params) { { event_id: event.id, roundtable_id: roundtable.id } }

      it 'queues a job to produce roundable chat history' do
        get download_event_chat_organisers_event_path(event), params: params
        expect(response).to redirect_to(dashboard_organisers_event_path(event))
        job_id = OrganiserJob.last.id
        expect(EventChatReportJob).to have_been_enqueued.with(job_id,
                                                              { event_id: event.id, roundtable_id: roundtable.id })
      end
    end

    describe 'backstage chat history' do
      let(:stage_part) { event.event_parts.stage.first }
      let(:backstage) { event.backstage }
      let(:params) { { event_id: event.id, backstage_id: backstage.id } }

      it 'queues a job to produce backstage chat history' do
        get download_event_chat_organisers_event_path(event), params: params
        expect(response).to redirect_to(dashboard_organisers_event_path(event))
        job_id = OrganiserJob.last.id
        expect(EventChatReportJob).to have_been_enqueued.with(job_id,
                                                              { event_id: event.id, backstage_id: backstage.id })
      end
    end

    describe 'stage chat history' do
      let(:stage_part) { event.event_parts.stage.first }
      let(:stage) { event.backstage.stage }
      let(:params) { { event_id: event.id, stage_id: stage.id } }

      it 'queues a job to produce stage chat history' do
        get download_event_chat_organisers_event_path(event), params: params
        expect(response).to redirect_to(dashboard_organisers_event_path(event))
        job_id = OrganiserJob.last.id
        expect(EventChatReportJob).to have_been_enqueued.with(job_id,
                                                              { event_id: event.id, stage_id: stage.id })
      end
    end
  end

  describe 'PUT /organisers/events/:id' do
    subject(:update_event) { put organisers_event_path(id: event.id), params: { event: event_params } }

    let(:event_params) { { max_age: 65 } }

    setup do
      sign_in(organiser_user)
    end

    it 'updates the event' do
      expect { update_event }.to change { event.reload.max_age }.to(65)
    end

    context 'when an event has schedules' do
      let(:session_part) { create(:event_part, event_part_type: 'sessions', event: event) }
      let!(:schedule) { create(:schedule, event_part: session_part, event: event) }

      it 'updates the event' do
        expect { update_event }.to change { event.reload.max_age }.to(65)
      end

      context 'when an event schedule is updated' do
        let(:time_start) { Time.find_zone(timezone).now.round }
        let(:event_params) do
          {
            schedules_attributes: {
              '0': { time_start: time_start + 2.hours, id: schedule.id },
            },
          }
        end

        it 'sanitizes the schedule attributes to ensure correct timezones' do
          expect { update_event }.to change { schedule.reload.time_start }.to(time_start + 2.hours)
        end

        context 'when the event is in a non-UTC timezone' do
          let(:timezone) { 'America/New_York' }

          it 'sanitizes the schedule attributes to ensure correct timezones' do
            expect { update_event }.to change { schedule.reload.time_start }.to(time_start + 2.hours)
          end
        end
      end
    end
  end

  describe 'GET /organisers/events/:id/sessions_summary' do
    before { sign_in(organiser_user) }

    let(:session_part) { create(:event_part, event_part_type: 'sessions', event: event) }
    let!(:roundtable) { create(:roundtable, event: event, event_part: session_part) }
    let!(:roundtable_private) { create(:roundtable, :private, event: event, event_part: session_part) }

    context 'when there is a private roundtable' do
      it 'does not return private roundtable' do
        get sessions_summary_organisers_event_path(event)

        expect(assigns(:sessions)).to match_array([roundtable])
        expect(assigns(:sessions)).not_to include([roundtable_private])
      end
    end

    context 'when there are more than 20 roundtables' do
      setup do
        create_list(:roundtable, 22, event: event, event_part: session_part)
      end

      it 'paginates the registrations' do
        get sessions_summary_organisers_event_path(event)

        expect(assigns(:sessions).size).to eq 20
      end
    end
  end

  describe 'GET /publish' do
    subject(:publish_event) { get publish_organisers_event_path(event) }

    before { sign_in(organiser_user) }

    context 'when event is draft' do
      let(:event) do
        create(:event, status: :draft, organization: organization, timezone: timezone, time_start: time_start)
      end
      let(:persona) { create(:persona, event: event) }

      context 'when event start time is in the past' do
        let(:time_start) { Time.zone.now - 1.day }

        it 'returns error' do
          publish_event

          expect(response).to redirect_to(dashboard_organisers_event_path(event))
          expect(flash[:alert]).to eq('Start date or End date can not be in past')
        end
      end

      context 'when event is not in past' do
        let(:time_start) { Time.zone.now + 5.minutes }

        it 'updates event status to live' do
          publish_event

          expect(response).to redirect_to(dashboard_organisers_event_path(event))
          expect(flash[:notice]).to eq('Event successfully marked as live')
          expect(event.reload.status).to eq('live')
        end
      end
    end

    context 'when event is live' do
      context 'when event does not have any attendee' do
        it 'updates event status to draft' do
          publish_event

          expect(response).to redirect_to(dashboard_organisers_event_path(event))
          expect(flash[:alert]).to eq('Event successfully marked as draft')
          expect(event.reload.status).to eq('draft')
        end
      end
    end
  end
end
