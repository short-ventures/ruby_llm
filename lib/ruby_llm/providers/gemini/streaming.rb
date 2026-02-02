# frozen_string_literal: true

module RubyLLM
  module Providers
    class Gemini
      # Streaming methods for the Gemini API implementation
      module Streaming
        def stream_url
          "models/#{@model}:streamGenerateContent?alt=sse"
        end

        def build_chunk(data)
          parts = data.dig('candidates', 0, 'content', 'parts') || []

          # Check if any parts contain functionCall data
          function_call_parts = parts.select { |p| p['functionCall'] }
          if function_call_parts.any?
            # Log detailed function call data including partialArgs detection
            function_call_parts.each do |part|
              fc = part['functionCall']
              has_partial_args = fc.key?('partialArgs') || fc.key?('partial_args')
              has_args = fc.key?('args')
              will_continue = fc['willContinue'] || fc['will_continue']

              RubyLLM.logger.info "[StreamingToolCall] functionCall detected: " \
                "name=#{fc['name']}, " \
                "hasPartialArgs=#{has_partial_args}, " \
                "hasArgs=#{has_args}, " \
                "willContinue=#{will_continue}, " \
                "keys=#{fc.keys.join(',')}"

              if has_partial_args
                partial = fc['partialArgs'] || fc['partial_args']
                RubyLLM.logger.info "[StreamingToolCall] partialArgs content: #{partial.to_json}"
              end
            end
          end

          tool_calls = extract_tool_calls(data)

          if tool_calls&.any?
            tool_calls.each do |id, tc|
              is_partial = tc.arguments.is_a?(Hash) && tc.arguments[:_partial]
              RubyLLM.logger.info "[StreamingToolCall] Extracted: id=#{id}, name=#{tc.name}, isPartial=#{is_partial}"
            end
          end

          Chunk.new(
            role: :assistant,
            model_id: extract_model_id(data),
            content: extract_text_content(parts),
            thinking: Thinking.build(
              text: extract_thought_content(parts),
              signature: extract_thought_signature(parts)
            ),
            input_tokens: extract_input_tokens(data),
            output_tokens: extract_output_tokens(data),
            thinking_tokens: data.dig('usageMetadata', 'thoughtsTokenCount'),
            tool_calls: tool_calls
          )
        end

        private

        def extract_model_id(data)
          data['modelVersion']
        end

        def extract_text_content(parts)
          text_parts = parts.reject { |p| p['thought'] }
          text = text_parts.filter_map { |p| p['text'] }.join
          text.empty? ? nil : text
        end

        def extract_thought_content(parts)
          thought_parts = parts.select { |p| p['thought'] }
          thoughts = thought_parts.filter_map { |p| p['text'] }.join
          thoughts.empty? ? nil : thoughts
        end

        def extract_thought_signature(parts)
          parts.each do |part|
            signature = part['thoughtSignature'] ||
                        part['thought_signature'] ||
                        part.dig('functionCall', 'thoughtSignature') ||
                        part.dig('functionCall', 'thought_signature')
            return signature if signature
          end

          nil
        end

        def extract_input_tokens(data)
          data.dig('usageMetadata', 'promptTokenCount')
        end

        def extract_output_tokens(data)
          candidates = data.dig('usageMetadata', 'candidatesTokenCount') || 0
          thoughts = data.dig('usageMetadata', 'thoughtsTokenCount') || 0
          total = candidates + thoughts
          total.positive? ? total : nil
        end

        def parse_streaming_error(data)
          error_data = JSON.parse(data)
          [error_data['error']['code'], error_data['error']['message']]
        rescue JSON::ParserError => e
          RubyLLM.logger.debug "Failed to parse streaming error: #{e.message}"
          [500, "Failed to parse error: #{data}"]
        end
      end
    end
  end
end
