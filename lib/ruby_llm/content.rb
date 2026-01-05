# frozen_string_literal: true

module RubyLLM
  # Represents the content sent to or received from an LLM.
  class Content
    attr_reader :text, :attachments

    def initialize(text = nil, attachments = nil)
      @text = text
      @attachments = []

      process_attachments(attachments)
      raise ArgumentError, 'Text and attachments cannot be both nil' if @text.nil? && @attachments.empty?
    end

    def add_attachment(source, filename: nil)
      @attachments << Attachment.new(source, filename:)
      self
    end

    def format
      if @text && @attachments.empty?
        @text
      else
        self
      end
    end

    # For Rails serialization
    def to_h
      { text: @text, attachments: @attachments.map(&:to_h) }
    end

    private

    def process_attachments_array_or_string(attachments)
      Utils.to_safe_array(attachments).each do |file|
        add_attachment(file)
      end
    end

    def process_attachments(attachments)
      if attachments.is_a?(Hash)
        attachments.each_value { |attachment| process_attachments_array_or_string(attachment) }
      else
        process_attachments_array_or_string attachments
      end
    end
  end
end

module RubyLLM
  class Content
    # Represents provider-specific payloads that should bypass RubyLLM formatting.
    class Raw
      attr_reader :value

      def initialize(value)
        raise ArgumentError, 'Raw content payload cannot be nil' if value.nil?

        @value = value
      end

      def format
        @value
      end

      def to_h
        @value
      end
    end

    # Lazy content that defers attachment downloading until format is called.
    # This avoids downloading attachments during to_llm conversion, allowing
    # message filtering (like ContextOptimizer) to run before any downloads occur.
    class Lazy
      attr_reader :text

      def initialize(text, attachment_blobs)
        @text = text
        @attachment_blobs = attachment_blobs
        @resolved = nil
        @tempfiles = []
      end

      def attachments
        resolve_if_needed
        @resolved.attachments
      end

      def format
        resolve_if_needed
        @resolved.format
      end

      def to_h
        resolve_if_needed
        @resolved.to_h
      end

      private

      def resolve_if_needed
        return if @resolved

        @resolved = Content.new(@text).tap do |content_obj|
          @attachment_blobs.each do |blob|
            tempfile = download_blob(blob)
            content_obj.add_attachment(tempfile, filename: blob.filename.to_s)
          end
        end
      end

      def download_blob(blob)
        ext = File.extname(blob.filename.to_s)
        basename = File.basename(blob.filename.to_s, ext)
        tempfile = Tempfile.new([basename, ext])
        tempfile.binmode

        blob.download { |chunk| tempfile.write(chunk) }

        tempfile.flush
        tempfile.rewind
        @tempfiles << tempfile
        tempfile
      end
    end
  end
end
