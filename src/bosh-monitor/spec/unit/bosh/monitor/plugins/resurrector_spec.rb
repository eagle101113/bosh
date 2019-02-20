require 'spec_helper'

module Bosh::Monitor::Plugins
  describe Resurrector do
    include Support::UaaHelpers

    let(:options) do
      {
        'director' => {
          'endpoint' => 'http://foo.bar.com:25555',
          'user' => 'user',
          'password' => 'password',
          'client_id' => 'client-id',
          'client_secret' => 'client-secret',
          'ca_cert' => 'ca-cert',
        },
      }
    end
    let(:plugin) { Bhm::Plugins::Resurrector.new(options) }
    let(:uri) { 'http://foo.bar.com:25555' }
    let(:status_uri) { "#{uri}/info" }

    before do
      stub_request(:get, status_uri).
        to_return(status: 200, body: JSON.dump({'user_authentication' => user_authentication}))
    end

    let(:alert) { Bhm::Events::Base.create!(:alert, alert_payload(deployment: 'd', job: 'j', instance_id: 'i', severity: 1)) }
    let(:aggregated_alert) { Bhm::Events::Base.create!(
      :alert, alert_payload(deployment: 'mydeployment',
                            jobs_to_instance_ids: { 'job-1': ['instance-id-1', 'instance-id-3'], 'job-2': ['instance-id-2'] },
                            severity: 1)) }


    let(:user_authentication) do
      {}
    end

    context 'when the event machine reactor is not running' do
      it 'should not start' do
        expect(plugin.run).to be(false)
      end
    end

    context 'when the event machine reactor is running' do
      around do |example|
        EM.run do
          example.call
          EM.stop
        end
      end

      context 'alerts with deployment, job and id' do
        let(:event_processor) { Bhm::EventProcessor.new }
        let(:state) { double(Bhm::Plugins::ResurrectorHelper::DeploymentState, :managed? => true, :meltdown? => false, :summary => 'summary') }

        before do
          Bhm.event_processor = event_processor
          @don = double(Bhm::Plugins::ResurrectorHelper::AlertTracker, record: nil, state_for: state)
          expect(Bhm::Plugins::ResurrectorHelper::AlertTracker).to receive(:new).and_return(@don)
        end

        it 'should be delivered' do
          plugin.run

          request_url = "#{uri}/deployments/d/scan_and_fix"
          request_data = {
              head: {
                  'Content-Type' => 'application/json',
                  'authorization' => %w[user password]
              },
              body: '{"jobs":{"j":["i"]}}'
          }
          expect(plugin).to receive(:send_http_put_request).with(request_url, request_data)

          plugin.process(alert)
        end

        context 'when auth provider is using UAA token issuer' do
          let(:user_authentication) do
            {
              'type' => 'uaa',
              'options' => {
                'url' => 'uaa-url',
              }
            }
          end

          before do
            token_issuer = instance_double(CF::UAA::TokenIssuer)

            allow(File).to receive(:exist?).with('ca-cert').and_return(true)
            allow(File).to receive(:read).with('ca-cert').and_return("test")

            allow(CF::UAA::TokenIssuer).to receive(:new).with(
              'uaa-url', 'client-id', 'client-secret', {ssl_ca_file: 'ca-cert'}
            ).and_return(token_issuer)
            allow(token_issuer).to receive(:client_credentials_grant).
              and_return(token)
          end
          let(:token) { uaa_token_info('fake-token-id') }

          it 'uses UAA token' do
            plugin.run

            request_url = "#{uri}/deployments/d/scan_and_fix"
            request_data = {
              head: {
                'Content-Type' => 'application/json',
                'authorization' => token.auth_header
              },
              body: '{"jobs":{"j":["i"]}}'
            }
            expect(plugin).to receive(:send_http_put_request).with(request_url, request_data)

            plugin.process(alert)
          end
        end

        context 'while melting down' do
          let(:state) { double(Bhm::Plugins::ResurrectorHelper::DeploymentState, :managed? => false, :meltdown? => true, :summary => 'summary') }

          it 'does not send requests to scan and fix' do
            plugin.run
            expect(plugin).not_to receive(:send_http_put_request)
            plugin.process(alert)
          end

          it 'sends alerts to the EventProcessor' do
            expected_time = Time.new
            allow(Time).to receive(:now).and_return(expected_time)
            alert_option = {
                :severity => 1,
                :title => "We are in meltdown",
                :summary => "Skipping resurrection for instance: 'j/i'; summary",
                :source => "HM plugin resurrector",
                :deployment => "d",
                :created_at => expected_time.to_i
            }
            expect(event_processor).to receive(:process).with(:alert, alert_option)
            plugin.run
            plugin.process(alert)
          end
        end

        context 'when resurrection is disabled' do
          let(:resurrection_manager) { double(Bosh::Monitor::ResurrectionManager, resurrection_enabled?: false) }
          before { allow(Bhm).to receive(:resurrection_manager).and_return(resurrection_manager) }

          it 'does not send requests to scan and fix' do
            plugin.run
            expect(plugin).not_to receive(:send_http_put_request)
            plugin.process(alert)
          end

          it 'sends alerts to the EventProcessor' do
            expected_time = Time.new
            allow(Time).to receive(:now).and_return(expected_time)
            alert_option = {
              severity: 1,
              title: 'Resurrection is disabled by resurrection config',
              summary: "Skipping resurrection for instance: 'j/i'; summary because of resurrection config",
              source: 'HM plugin resurrector',
              deployment: 'd',
              created_at: expected_time.to_i,
            }
            expect(event_processor).to receive(:process).with(:alert, alert_option)
            plugin.run
            plugin.process(alert)
          end
        end
      end

      context 'alerts without deployment, job and id' do
        let(:alert) { Bhm::Events::Base.create!(:alert, alert_payload) }

        it 'should not be delivered' do
          plugin.run

          expect(plugin).not_to receive(:send_http_put_request)

          plugin.process(alert)
        end
      end

      context 'when director status is not 200' do
        before do
          stub_request(:get, status_uri).to_return(status: 500, headers: {}, body: 'Failed')
        end

        it 'returns false' do
          plugin.run

          expect(plugin).not_to receive(:send_http_put_request)

          plugin.process(alert)
        end

        context 'when director starts responding' do
          before do
            state = double(Bhm::Plugins::ResurrectorHelper::DeploymentState, :managed? => true, :meltdown? => false, :summary => 'summary')
            expect(Bhm::Plugins::ResurrectorHelper::DeploymentState).to receive(:new).and_return(state)
            stub_request(:get, status_uri).to_return({status: 500}, {status: 200, body: '{}'})
          end

          it 'starts sending alerts' do
            plugin.run

            expect(plugin).to receive(:send_http_put_request).once

            plugin.process(alert) # fails to send request
            plugin.process(alert)
          end
        end
      end
    end
  end
end
