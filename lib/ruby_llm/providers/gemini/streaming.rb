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
          thoughts = extract_thoughts(data)

          Chunk.new(
            role: :assistant,
            model_id: extract_model_id(data),
            content: extract_content(data),
            thoughts: thoughts,
            input_tokens: extract_input_tokens(data),
            output_tokens: extract_output_tokens(data),
            tool_calls: extract_tool_calls(data)
          )
        end

        private

        def extract_model_id(data)
          data['modelVersion']
        end

        def extract_content(data)
          return nil unless data['candidates']&.any?

          candidate = data['candidates'][0]
          parts = candidate.dig('content', 'parts')
          return nil unless parts

          parts = filter_thought_parts(parts, candidate, data)

          text_parts = parts.select { |p| p['text'] }
          text_parts.map { |p| p['text'] }.join if text_parts.any?
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

        def extract_thoughts(data)
          candidate = data.dig('candidates', 0)
          parts = candidate.is_a?(Hash) ? candidate.dig('content', 'parts') : nil
          collect_thought_texts(candidate, data, parts)
        end

        def parse_streaming_error(data)
          error_data = JSON.parse(data)
          [error_data['error']['code'], error_data['error']['message']]
        rescue JSON::ParserError => e
          RubyLLM.logger.debug "Failed to parse streaming error: #{e.message}"
          [500, "Failed to parse error: #{data}"]
        end

        def filter_thought_parts(parts, candidate, data)
          thought_texts = collect_thought_texts(candidate, data, parts)
          return parts if thought_texts.empty?

          parts.reject { |part| part['text'] && thought_texts.include?(part['text']) }
        end

        def collect_thought_texts(candidate, data, parts = [])
          collections = []
          collections << candidate['thoughts'] if candidate.is_a?(Hash) && candidate['thoughts']
          collections << data['thoughts'] if data.is_a?(Hash) && data['thoughts']
          collections << extract_thought_parts(parts)

          collections.flatten.compact.flat_map do |entry|
            next entry if entry.is_a?(String)
            next [] unless entry.is_a?(Hash)

            texts = []
            texts << entry['text'] if entry['text']

            content_parts = entry.dig('content', 'parts')
            if content_parts.is_a?(Array)
              content_parts.each do |part|
                texts << part['text'] if part.is_a?(Hash) && part['text']
              end
            end

            texts
          end.compact
        end

        def extract_thought_parts(parts)
          Array(parts).filter_map do |part|
            next unless part.is_a?(Hash) && part['thought']
            part['text']
          end
        end
      end
    end
  end
end
