# frozen_string_literal: true

module BotOps
  # A detail box drawn over the dashboard (Scene#open_overlay). Its content
  # is a list of fields ("label: value") and blocks (a heading over
  # preformatted text, such as a command or a prompt). Scene lays it out into
  # monospaced lines for the box's width and shows a scrolling window of them;
  # #offset is the first line shown.
  class Overlay
    Section = Struct.new(:kind, :label, :text)

    attr_reader :title, :subtitle, :sections
    attr_accessor :offset

    def initialize(title, subtitle: nil)
      @title = title.to_s
      @subtitle = subtitle
      @sections = []
      @offset = 0
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

    # Lines for a box `cols` characters wide, each [style, text] or, for a
    # field's first line, [:field, label, value].
    def lines(cols)
      cols = [cols, 20].max
      label_w = @sections.select { |s| s.kind == :field }.map { |s| s.label.length }.max.to_i + 2
      out = []
      @sections.each do |s|
        case s.kind
        when :field
          wrap(s.text, cols - label_w).each_with_index do |part, i|
            out << (i.zero? ? [:field, s.label, part, label_w] : [:continued, " " * label_w + part])
          end
        when :block
          out << [:blank, ""] unless out.empty?
          out << [:heading, s.label]
          s.text.split("\n", -1).each { |l| wrap(l, cols).each { |part| out << [:mono, part] } }
        when :note
          out << [:blank, ""] unless out.empty?
          wrap(s.text, cols).each { |part| out << [:note, part] }
        end
      end
      out
    end

    def scroll_by(lines)
      @offset = [@offset + lines, 0].max
    end

    private

    # Hard wrap at `cols` characters (the box uses a monospaced font).
    def wrap(text, cols)
      text = text.to_s.gsub("\t", "  ")
      return [""] if text.empty?
      text.scan(/.{1,#{cols}}/m)
    end
  end
end
