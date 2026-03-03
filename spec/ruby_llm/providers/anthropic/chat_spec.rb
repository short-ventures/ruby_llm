# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::Anthropic::Chat do
  describe '.render_payload' do
    let(:model) { instance_double(RubyLLM::Model::Info, id: 'claude-sonnet-4-5', max_tokens: nil) }

    it 'embeds raw system content blocks unchanged' do
      system_raw = RubyLLM::Providers::Anthropic::Content.new(
        'avoid greetings',
        cache_control: { type: 'ephemeral' }
      )

      system_message = RubyLLM::Message.new(role: :system, content: system_raw)
      user_message = RubyLLM::Message.new(role: :user, content: 'Hello there')

      payload = described_class.render_payload(
        [system_message, user_message],
        tools: {},
        temperature: nil,
        model: model,
        stream: false,
        schema: nil
      )

      expect(payload[:system]).to eq(system_raw.value)
      expect(payload[:messages].first[:content]).to eq([{ type: 'text', text: 'Hello there' }])
    end

    it 'renders reasoning effort when thinking effort is configured' do
      user_message = RubyLLM::Message.new(role: :user, content: 'Hello there')
      thinking = RubyLLM::Thinking::Config.new(effort: :low)

      payload = described_class.render_payload(
        [user_message],
        tools: {},
        temperature: nil,
        model: model,
        stream: false,
        schema: nil,
        thinking: thinking
      )

      expect(payload[:reasoning]).to eq({ effort: 'low' })
      expect(payload).not_to have_key(:thinking)
    end

    it 'falls back to legacy thinking budget payload when only budget is configured' do
      user_message = RubyLLM::Message.new(role: :user, content: 'Hello there')
      thinking = RubyLLM::Thinking::Config.new(budget: 1024)

      payload = described_class.render_payload(
        [user_message],
        tools: {},
        temperature: nil,
        model: model,
        stream: false,
        schema: nil,
        thinking: thinking
      )

      expect(payload[:thinking]).to eq({ type: 'enabled', budget_tokens: 1024 })
      expect(payload).not_to have_key(:reasoning)
    end
  end

  describe '.parse_completion_response' do
    it 'captures cache usage metrics on the message' do
      response_body = {
        'model' => 'claude-sonnet-4-5-20250929',
        'content' => [{ 'type' => 'text', 'text' => 'Hi!' }],
        'usage' => {
          'input_tokens' => 42,
          'output_tokens' => 5,
          'cache_read_input_tokens' => 21,
          'cache_creation_input_tokens' => 7
        }
      }

      response = instance_double(Faraday::Response, body: response_body)

      message = described_class.parse_completion_response(response)

      expect(message.input_tokens).to eq(42)
      expect(message.output_tokens).to eq(5)
      expect(message.cached_tokens).to eq(21)
      expect(message.cache_creation_tokens).to eq(7)
    end
  end
end
