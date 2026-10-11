# frozen_string_literal: true

module BotOps
  # A detail box drawn over the dashboard (Scene#open_overlay). Its content
  # is a list of fields ("label: value"), blocks (a heading over text shown
  # exactly as written, such as a command or a prompt) and notes (prose).
  #
  # Fields and blocks are never wrapped: code's line breaks and indentation
  # carry its meaning, so long lines run on and the box scrolls sideways
  # instead (#x_offset, in points). Only notes, plain sentences, wrap, and
  # only between words. #offset is the first line shown.
  class Overlay
    Section = Struct.new(:kind, :label, :text)

    attr_reader :title, :subtitle, :sections
    attr_accessor :offset, :x_offset

    def initialize(title, subtitle: nil)
      @title = title.to_s
      @subtitle = subtitle
      @sections = []
      @offset = 0
      @x_offset = 0.0
    end

    def field(label, value)
      @sections << Section.new(:field, label.to_s, value.to_s) unless value.nil? || value.to_s.empty?
      self
    end

    def block(label, text)
      @sections << Section.new(:block, label.to_s, text.to_s) unless text.nil? || text.to_s.strip.empty?
      self
    end

    def note(text)
      @sections << Section.new(:note, nil, text.to_s)
      self
    end

    # The box's lines, each [style, text] or, for a field, [:field, label,
    # value, label_width]. `note_cols` is how wide notes may wrap.
    def lines(note_cols = 100)
      label_w = @sections.select { |s| s.kind == :field }.map { |s| s.label.length }.max.to_i + 2
      out = []
      @sections.each do |s|
        case s.kind
        when :field
          out << [:field, s.label, s.text.tr("\n", " "), label_w]
        when :block
          out << [:blank, ""] unless out.empty?
          out << [:heading, s.label]
          s.text.gsub("\t", "  ").split("\n", -1).each { |l| out << [:mono, l] }
        when :note
          out << [:blank, ""] unless out.empty?
          word_wrap(s.text, note_cols).each { |l| out << [:note, l] }
        end
      end
      out
    end

    # Width of a line in characters (a field's label column included).
    def self.columns(line)
      line[0] == :field ? line[3] + line[2].length : line[1].to_s.length
    end

    def scroll_by(lines)
      @offset = [@offset + lines, 0].max
    end

    def pan_by(points)
      @x_offset = [@x_offset + points, 0].max
    end

    private

    # Prose only: break between words, never inside one.
    def word_wrap(text, cols)
      cols = [cols, 20].max
      text.split(/\s+/).each_with_object([+""]) do |word, lines|
        if lines.last.empty?
          lines.last << word
        elsif lines.last.length + 1 + word.length <= cols
          lines.last << " " << word
        else
          lines << word.dup
        end
      end
    end
  end
end
