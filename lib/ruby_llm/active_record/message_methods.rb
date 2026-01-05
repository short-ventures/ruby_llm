# frozen_string_literal: true

module RubyLLM
  module ActiveRecord
    # Methods mixed into message models.
    module MessageMethods
      extend ActiveSupport::Concern

      class_methods do
        attr_reader :chat_class, :tool_call_class, :chat_foreign_key, :tool_call_foreign_key
      end

      def to_llm
        cached = has_attribute?(:cached_tokens) ? self[:cached_tokens] : nil
        cache_creation = has_attribute?(:cache_creation_tokens) ? self[:cache_creation_tokens] : nil

        RubyLLM::Message.new(
          role: role.to_sym,
          content: extract_content,
          tool_calls: extract_tool_calls,
          tool_call_id: extract_tool_call_id,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cached_tokens: cached,
          cache_creation_tokens: cache_creation,
          model_id: model_association&.model_id
        )
      end

      private

      def extract_tool_calls
        tool_calls_association.to_h do |tool_call|
          [
            tool_call.tool_call_id,
            RubyLLM::ToolCall.new(
              id: tool_call.tool_call_id,
              name: tool_call.name,
              arguments: tool_call.arguments,
              thought_signature: tool_call.try(:thought_signature)
            )
          ]
        end
      end

      def extract_tool_call_id
        parent_tool_call&.tool_call_id
      end

      def extract_content
        # Fast path: use cached content_raw if available (no downloads needed)
        return RubyLLM::Content::Raw.new(content_raw) if has_attribute?(:content_raw) && content_raw.present?

        content_value = self[:content]

        # No attachments: return plain text
        return content_value unless respond_to?(:attachments) && attachments.attached?

        # Lazy loading: defer attachment downloads until format is called.
        # This allows message filtering (ContextOptimizer) to run before any S3 downloads.
        # Only messages that survive the filter will have their attachments downloaded.
        RubyLLM::Content::Lazy.new(content_value, attachments.blobs.to_a)
      end
    end
  end
end
