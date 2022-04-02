# frozen_string_literal: true

require 'api_helper'

describe EventsHelper, mocks: [:opentok] do
  describe 'with mocks' do
    subject(:helper) do
      klass = Class.new do
        include EventsHelper
        def request
          OpenStruct.new(procol: 'https')
        end
      end
      klass.new
    end

    before do
      stub_env('HOPIN_WEB_URL' => 'https://app.hopin.to')
    end

    describe 'backstage_url(event)' do
      let(:event) { create(:event, :with_stage, slug: 'some-event') }
      let(:backstage_uuid) { '1a1a-2b2b-3c3c' }

      before do
        allow(event.backstage).to receive(:uuid) { backstage_uuid }
      end

      it 'produces a valid backstage url' do
        expect(helper.backstage_url(event)).to eq 'https://app.hopin.to/events/some-event/backstage/1a1a-2b2b-3c3c'
      end
    end

    describe 'roundtable_url(event, roundtable)' do
      let(:event) { create(:event, :with_sessions, slug: 'some-event') }
      let(:session_part) { event.event_parts.sessions.first }
      let(:roundtable_uuid) { '1a1a-2b2b-3c3c' }
      let(:roundtable) { create(:roundtable, event_part: session_part) }

      before do
        allow(roundtable).to receive(:uuid) { roundtable_uuid }
      end

      it 'creates a valid url for the roundtable using UUID' do
        expect(helper.roundtable_url(event, roundtable)).to eq 'https://app.hopin.to/events/some-event/sessions/1a1a-2b2b-3c3c'
      end
    end
  end
end
