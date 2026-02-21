# frozen_string_literal: true

module RubyLLM
  # Assembles streaming responses from LLMs into complete messages.
  class StreamAccumulator
    attr_reader :content, :model_id, :tool_calls, :time_to_first_token, :streaming_duration

    def initialize
      @content = +''
      @thinking_text = +''
      @thinking_signature = nil
      @tool_calls = {}
      @thought_signature = nil
      @input_tokens = nil
      @output_tokens = nil
      @cached_tokens = nil
      @cache_creation_tokens = nil
      @thinking_tokens = nil
      @inside_think_tag = false
      @pending_think_tag = +''
      @latest_tool_call_id = nil
      # Timing instrumentation
      @stream_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @first_chunk_time = nil
      @time_to_first_token = nil
      @streaming_duration = nil
    end

    def add(chunk)
      RubyLLM.logger.debug chunk.inspect if RubyLLM.config.log_stream_debug

      # Record time-to-first-token on first chunk with content
      if @first_chunk_time.nil? && (chunk_has_content?(chunk.content) || chunk.tool_call?)
        @first_chunk_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @time_to_first_token = ((@first_chunk_time - @stream_start_time) * 1000).round(1)
      end

      @model_id ||= chunk.model_id

      handle_chunk_content(chunk)
      append_thinking_from_chunk(chunk)
      count_tokens chunk
      RubyLLM.logger.debug inspect if RubyLLM.config.log_stream_debug
    end

    def to_message(response)
      # Calculate total streaming duration
      stream_end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @streaming_duration = ((stream_end_time - @stream_start_time) * 1000).round(1)

      Message.new(
        role: :assistant,
        content: content.empty? ? nil : content,
        thinking: Thinking.build(
          text: @thinking_text.empty? ? nil : @thinking_text,
          signature: @thinking_signature
        ),
        tokens: Tokens.build(
          input: @input_tokens,
          output: @output_tokens,
          cached: @cached_tokens,
          cache_creation: @cache_creation_tokens,
          thinking: @thinking_tokens
        ),
        model_id: model_id,
        tool_calls: tool_calls_from_stream,
        raw: response,
        time_to_first_token: @time_to_first_token,
        streaming_duration: @streaming_duration
      )
    end

    private

    def tool_calls_from_stream
      first = true
      # Filter out any tool calls without valid names before transforming
      valid_tool_calls = tool_calls.reject { |_id, tc| tc.name.nil? || tc.name.to_s.empty? }

      RubyLLM.logger.debug "[ToolCallsFromStream] Processing #{valid_tool_calls.size} tool calls"

      valid_tool_calls.transform_values do |tc|
        RubyLLM.logger.debug "[ToolCallsFromStream] Tool: #{tc.name}, raw args type: #{tc.arguments.class}, raw args: #{tc.arguments.inspect}"

        arguments = case tc.arguments
                    when String
                      tc.arguments.empty? ? {} : parse_tool_arguments(tc.arguments)
                    when Hash
                      # Remove internal tracking keys from partial args
                      tc.arguments.reject { |k, _| k.to_s.start_with?('_') }
                    else
                      {}
                    end

        RubyLLM.logger.debug "[ToolCallsFromStream] Tool: #{tc.name}, final args: #{arguments.inspect}"

        sig = tc.thought_signature || (first ? @thought_signature : nil)
        first = false if sig

        ToolCall.new(
          id: tc.id,
          name: tc.name,
          arguments: arguments,
          thought_signature: sig
        )
      end
    end

    def chunk_has_content?(content)
      return false if content.nil?
      return !content.empty? if content.respond_to?(:empty?)

      true
    end

    def parse_tool_arguments(arguments_string)
      JSON.parse(arguments_string)
    rescue JSON::ParserError => e
      RubyLLM.logger.error "Failed to parse streaming tool arguments: #{e.message}"
      {}
    end

    def accumulate_tool_calls(new_tool_calls) # rubocop:disable Metrics/PerceivedComplexity,Metrics/AbcSize,Metrics/CyclomaticComplexity
      RubyLLM.logger.debug "Accumulating tool calls: #{new_tool_calls}" if RubyLLM.config.log_stream_debug
      new_tool_calls.each_value do |tool_call|
        if tool_call.id
          # Skip tool calls without a name - can't create a valid entry without it
          next if tool_call.name.nil? || tool_call.name.to_s.empty?

          tool_call_id = tool_call.id.empty? ? SecureRandom.uuid : tool_call.id

          # Check if this is a partial streaming tool call from Vertex AI
          if tool_call.arguments.is_a?(Hash) && tool_call.arguments[:_partial]
            handle_partial_tool_call(tool_call, tool_call_id)
          else
            # Complete tool call - store as-is
            tool_call_arguments = case tool_call.arguments
                                  when String
                                    tool_call.arguments.empty? ? +'' : +tool_call.arguments.dup
                                  when Hash
                                    tool_call.arguments.empty? ? +'' : +JSON.generate(tool_call.arguments)
                                  else
                                    +''
                                  end
            @thought_signature ||= tool_call.thought_signature
            @tool_calls[tool_call.id] = ToolCall.new(
              id: tool_call_id,
              name: tool_call.name,
              arguments: tool_call_arguments,
              thought_signature: tool_call.thought_signature
            )
            @latest_tool_call_id = tool_call.id
          end
        else
          # Continuation - append to latest tool call
          existing = @tool_calls[@latest_tool_call_id]
          if existing
            # Check if this is a partial args continuation (Vertex AI streaming)
            if tool_call.arguments.is_a?(Hash) && tool_call.arguments[:_partial]
              partial_args = tool_call.arguments[:_partial_args] || []
              RubyLLM.logger.debug "[Continuation] Merging partialArgs into existing tool call: #{existing.name}"
              merge_partial_args(existing, partial_args)
            else
              # Legacy string format continuation
              partial = tool_call.arguments.is_a?(String) ? tool_call.arguments : JSON.generate(tool_call.arguments)
              existing.arguments << partial if existing.arguments.is_a?(String)
            end
            if tool_call.thought_signature && existing.thought_signature.nil?
              existing.thought_signature = tool_call.thought_signature
            end
          else
            RubyLLM.logger.warn "[Continuation] No existing tool call found for continuation (latest_id=#{@latest_tool_call_id})"
          end
        end
      end
    end

    # Handle Vertex AI streaming partial tool calls with jsonPath-based arguments
    def handle_partial_tool_call(tool_call, tool_call_id) # rubocop:disable Metrics/AbcSize
      partial_args = tool_call.arguments[:_partial_args] || []
      will_continue = tool_call.arguments[:_will_continue]

      RubyLLM.logger.debug "[PartialToolCall] Processing: name=#{tool_call.name}, id=#{tool_call.id}, partialArgsCount=#{partial_args.size}, willContinue=#{will_continue}"
      RubyLLM.logger.debug "[PartialToolCall] Raw partialArgs: #{partial_args.inspect}"

      # Check if we already have an entry for this specific tool call ID
      # (handles case where same ID comes in multiple chunks)
      existing = @tool_calls[tool_call.id]

      if existing
        # Accumulate partial arguments into existing entry for same ID
        RubyLLM.logger.debug "[PartialToolCall] Merging into existing entry (same ID), current args: #{existing.arguments.inspect}"
        merge_partial_args(existing, partial_args)
        RubyLLM.logger.debug "[PartialToolCall] After merge, args: #{existing.arguments.inspect}"
        @latest_tool_call_id = tool_call.id
      else
        # New tool call - create entry with partial args
        # Use tool_call_id as key to support multiple calls to the same tool
        initial_args = {}
        merge_partial_args_into(initial_args, partial_args)
        RubyLLM.logger.debug "[PartialToolCall] Created new entry for id=#{tool_call_id}, initial args: #{initial_args.inspect}"

        @thought_signature ||= tool_call.thought_signature
        @tool_calls[tool_call.id] = ToolCall.new(
          id: tool_call_id,
          name: tool_call.name,
          arguments: initial_args,
          thought_signature: tool_call.thought_signature
        )
        @latest_tool_call_id = tool_call.id
      end
    end

    def merge_partial_args(existing_tool_call, partial_args)
      return unless partial_args.is_a?(Array)

      # Ensure arguments is a mutable hash
      if existing_tool_call.arguments.is_a?(String)
        existing_tool_call.arguments = existing_tool_call.arguments.empty? ? {} : JSON.parse(existing_tool_call.arguments)
      end

      merge_partial_args_into(existing_tool_call.arguments, partial_args)
    end

    def merge_partial_args_into(target_hash, partial_args)
      partial_args.each do |partial|
        next unless partial.is_a?(Hash)

        json_path = partial['jsonPath'] || partial[:jsonPath]
        next unless json_path

        # Extract value from the partial arg (numberValue, stringValue, boolValue, nullValue)
        value = extract_partial_value(partial)

        # Apply value at jsonPath (simplified - assumes single-level paths like "$.argName")
        set_value_at_path(target_hash, json_path, value, partial['willContinue'])
      end
    end

    def extract_partial_value(partial)
      value = if partial.key?('numberValue')
                partial['numberValue']
              elsif partial.key?(:numberValue)
                partial[:numberValue]
              elsif partial.key?('stringValue')
                partial['stringValue']
              elsif partial.key?(:stringValue)
                partial[:stringValue]
              elsif partial.key?('boolValue')
                partial['boolValue']
              elsif partial.key?(:boolValue)
                partial[:boolValue]
              elsif partial.key?('nullValue') || partial.key?(:nullValue)
                nil
              else
                RubyLLM.logger.warn "[ExtractPartialValue] Unknown value type in partial: #{partial.keys.join(', ')}"
                nil
              end
      RubyLLM.logger.debug "[ExtractPartialValue] Extracted value: #{value.inspect} from keys: #{partial.keys.join(', ')}"
      value
    end

    def set_value_at_path(target, json_path, value, will_continue = false)
      # Parse jsonPath like "$.argName", "$.foo.bar", or "$.components[0]"
      # Remove leading "$." and split by "." while handling array notation
      path_str = json_path.sub(/^\$\.?/, '')

      # Parse path into segments, handling array notation like "components[0]"
      segments = parse_json_path_segments(path_str)
      RubyLLM.logger.debug "[SetValueAtPath] path=#{json_path}, segments=#{segments.inspect}, value=#{value.inspect[0..100]}, willContinue=#{will_continue}"
      return if segments.empty?

      # Navigate to the parent container, creating arrays/hashes as needed
      current = target
      segments[0..-2].each_with_index do |segment, i|
        next_segment = segments[i + 1]
        current = navigate_or_create(current, segment, next_segment)
      end

      # Set the final value
      final_segment = segments.last
      set_segment_value(current, final_segment, value, will_continue)
    end

    def parse_json_path_segments(path_str)
      segments = []
      # Split by "." but preserve array notation
      path_str.scan(/([^\.\[]+)(?:\[(\d+)\])?/).each do |name, index|
        segments << { type: :key, key: name } if name && !name.empty?
        segments << { type: :index, index: index.to_i } if index
      end
      segments
    end

    def navigate_or_create(current, segment, next_segment)
      # Determine what type of container to create based on next segment
      create_array = next_segment && next_segment[:type] == :index

      if segment[:type] == :index
        idx = segment[:index]
        current[idx] ||= (create_array ? [] : {})
        current[idx]
      else
        key = segment[:key]
        current[key] ||= (create_array ? [] : {})
        current[key]
      end
    end

    def set_segment_value(current, segment, value, _will_continue)
      if segment[:type] == :index
        idx = segment[:index]
        # Ensure current is an array
        unless current.is_a?(Array)
          RubyLLM.logger.warn "[SetValueAtPath] Expected array for index #{idx}, got #{current.class}"
          return
        end

        # Vertex AI sends string values in multiple chunks:
        # - First chunk has the value with willContinue=true
        # - Last chunk has empty string with willContinue=false
        # We should always append if a string already exists, never overwrite
        if current[idx].is_a?(String)
          current[idx] += value.to_s
          RubyLLM.logger.debug "[SetValueAtPath] Appended to index=#{idx}, new length=#{current[idx].length}"
        else
          current[idx] = value
          RubyLLM.logger.debug "[SetValueAtPath] Set index=#{idx} to #{value.inspect[0..50]}"
        end
      else
        key = segment[:key]
        if current[key].is_a?(String)
          current[key] += value.to_s
          RubyLLM.logger.debug "[SetValueAtPath] Appended to key=#{key}, new length=#{current[key].length}"
        else
          current[key] = value
          RubyLLM.logger.debug "[SetValueAtPath] Set key=#{key} to #{value.inspect[0..50]}"
        end
      end
    end

    def count_tokens(chunk)
      @input_tokens = chunk.input_tokens if chunk.input_tokens
      @output_tokens = chunk.output_tokens if chunk.output_tokens
      @cached_tokens = chunk.cached_tokens if chunk.cached_tokens
      @cache_creation_tokens = chunk.cache_creation_tokens if chunk.cache_creation_tokens
      @thinking_tokens = chunk.thinking_tokens if chunk.thinking_tokens
    end

    def handle_chunk_content(chunk)
      return accumulate_tool_calls(chunk.tool_calls) if chunk.tool_call?

      content_text = chunk.content || ''
      if content_text.is_a?(String)
        append_text_with_thinking(content_text)
      else
        @content << content_text.to_s
      end
    end

    def append_text_with_thinking(text)
      content_chunk, thinking_chunk = extract_think_tags(text)
      @content << content_chunk
      @thinking_text << thinking_chunk if thinking_chunk
    end

    def append_thinking_from_chunk(chunk)
      thinking = chunk.thinking
      return unless thinking

      @thinking_text << thinking.text.to_s if thinking.text
      @thinking_signature ||= thinking.signature # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    def extract_think_tags(text)
      start_tag = '<think>'
      end_tag = '</think>'
      remaining = @pending_think_tag + text
      @pending_think_tag = +''

      output = +''
      thinking = +''

      until remaining.empty?
        remaining = if @inside_think_tag
                      consume_think_content(remaining, end_tag, thinking)
                    else
                      consume_non_think_content(remaining, start_tag, output)
                    end
      end

      [output, thinking.empty? ? nil : thinking]
    end

    def consume_think_content(remaining, end_tag, thinking)
      end_index = remaining.index(end_tag)
      if end_index
        thinking << remaining.slice(0, end_index)
        @inside_think_tag = false
        remaining.slice((end_index + end_tag.length)..) || +''
      else
        suffix_len = longest_suffix_prefix(remaining, end_tag)
        thinking << remaining.slice(0, remaining.length - suffix_len)
        @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
        +''
      end
    end

    def consume_non_think_content(remaining, start_tag, output)
      start_index = remaining.index(start_tag)
      if start_index
        output << remaining.slice(0, start_index)
        @inside_think_tag = true
        remaining.slice((start_index + start_tag.length)..) || +''
      else
        suffix_len = longest_suffix_prefix(remaining, start_tag)
        output << remaining.slice(0, remaining.length - suffix_len)
        @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
        +''
      end
    end

    def longest_suffix_prefix(text, tag)
      max = [text.length, tag.length - 1].min
      max.downto(1) do |len|
        return len if text.end_with?(tag[0, len])
      end
      0
    end
  end
end
