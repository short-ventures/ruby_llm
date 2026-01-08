# frozen_string_literal: true

module RubyLLM
  module ActiveRecord
    # Methods mixed into message models.
    module MessageMethods
      extend ActiveSupport::Concern

      class_methods do
        attr_reader :chat_class, :tool_call_class, :chat_foreign_key, :tool_call_foreign_key
      end

      # Thread-local cache for to_llm results, keyed by [message_id, updated_at, skip_attachments]
      # This survives across AR instance reloads within the same request/job
      def self.to_llm_cache
        Thread.current[:ruby_llm_message_cache] ||= {}
      end

      def self.clear_to_llm_cache!
        Thread.current[:ruby_llm_message_cache] = {}
      end

      def to_llm(skip_attachments: false)
        # Use thread-local cache to survive AR instance reloads
        cache = MessageMethods.to_llm_cache
        cache_key = [id, updated_at, skip_attachments]
        return cache[cache_key] if cache.key?(cache_key)

        cached = has_attribute?(:cached_tokens) ? self[:cached_tokens] : nil
        cache_creation = has_attribute?(:cache_creation_tokens) ? self[:cache_creation_tokens] : nil

        result = RubyLLM::Message.new(
          role: role.to_sym,
          content: extract_content(skip_attachments: skip_attachments),
          tool_calls: extract_tool_calls,
          tool_call_id: extract_tool_call_id,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cached_tokens: cached,
          cache_creation_tokens: cache_creation,
          model_id: model_association&.model_id
        )

        cache[cache_key] = result
      end

      # Clear the to_llm cache (useful if message content changes)
      def clear_to_llm_cache!
        MessageMethods.clear_to_llm_cache!
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

      def extract_content(skip_attachments: false)
        return RubyLLM::Content::Raw.new(content_raw) if has_attribute?(:content_raw) && content_raw.present?

        content_value = self[:content]
        has_attachments = respond_to?(:attachments) && attachments.attached?

        return content_value unless has_attachments

        # Skip downloading attachments for messages beyond the image context distance
        if skip_attachments
          return content_value.present? ? "#{content_value}\n\n[IMAGE CONTEXT EXPIRED]" : '[IMAGE CONTEXT EXPIRED]'
        end

        RubyLLM::Content.new(content_value).tap do |content_obj|
          @_tempfiles ||= []

          attachments.each do |attachment|
            tempfile = download_attachment(attachment)
            content_obj.add_attachment(tempfile, filename: attachment.filename.to_s)
          end
        end
      end

      def download_attachment(attachment)
        ext = File.extname(attachment.filename.to_s)
        basename = File.basename(attachment.filename.to_s, ext)
        tempfile = Tempfile.new([basename, ext])
        tempfile.binmode

        attachment.download { |chunk| tempfile.write(chunk) }

        tempfile.flush
        tempfile.rewind
        @_tempfiles << tempfile
        tempfile
      end
    end
  end
end
