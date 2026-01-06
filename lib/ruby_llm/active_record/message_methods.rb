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
        # #region agent log
        has_raw = has_attribute?(:content_raw) && content_raw.present?
        has_attachments = respond_to?(:attachments) && attachments.attached?
        File.open('/Users/calshort/blox/.cursor/debug.log', 'a') { |f| f.puts({hypothesisId:'H2',location:'message_methods.rb:extract_content',message:'extract_content called',data:{msg_id:id,role:role,has_raw:has_raw,has_attachments:has_attachments,attachment_count:has_attachments ? attachments.count : 0},timestamp:Time.now.to_i*1000}.to_json) }
        # #endregion
        return RubyLLM::Content::Raw.new(content_raw) if has_raw

        content_value = self[:content]

        return content_value unless has_attachments

        RubyLLM::Content.new(content_value).tap do |content_obj|
          @_tempfiles = []

          attachments.each do |attachment|
            # #region agent log
            File.open('/Users/calshort/blox/.cursor/debug.log', 'a') { |f| f.puts({hypothesisId:'H2',location:'message_methods.rb:download_attachment',message:'downloading attachment from S3',data:{msg_id:id,filename:attachment.filename.to_s,key:attachment.key},timestamp:Time.now.to_i*1000}.to_json) }
            # #endregion
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
