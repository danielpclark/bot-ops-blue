# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "tmpdir"

class DotArtTest < Minitest::Test
  D = BotOps::DotArt

  def grid(sprite)
    D.parse_rows(sprite["rows"])
  end

  def test_identicon_is_deterministic_and_symmetric
    a = D.identicon("Bot Ops", body: "#30C8FC")
    b = D.identicon("  bot ops ", body: "#30C8FC")
    assert_equal a, b, "the same name, however written, gives the same face"
    rows = grid(a)
    assert_equal [7, 7], [rows.size, rows.first.size]
    rows.each { |r| assert_equal r.map { |c| c.nil? }, r.reverse.map { |c| c.nil? }, "columns mirror" }
    assert rows.first.all?(&:nil?), "the top row is head room"
    assert_equal({ "#" => "#30C8FC", "+" => "#64D6FD", "o" => "pink" }, a["palette"])
  end

  def test_different_names_differ
    faces = %w[Bot\ Ops George Legal\ -\ Contracts Legal\ -\ Filing].map { |n| D.identicon(n)["rows"] }
    assert_equal faces.size, faces.uniq.size
  end

  def test_eyes_always_lit
    %w[a b c Bot\ Ops George x y z].each do |name|
      rows = D.identicon(name)["rows"]
      assert_equal "o", rows[2][2], name
      assert_equal "o", rows[2][4], name
    end
  end

  def test_edge_cells_are_the_lit_ones_touching_an_unlit_one
    rows = grid(D.identicon("George"))
    rows.each_with_index do |row, r|
      row.each_with_index do |ch, c|
        next if ch.nil? || ch == "o"
        around = [[r - 1, c], [r + 1, c], [r, c - 1], [r, c + 1]].any? { |rr, cc| !rr.between?(0, 6) || !cc.between?(0, 6) || rows[rr][cc].nil? }
        assert_equal around ? "+" : "#", ch, "cell #{r},#{c}"
      end
    end
  end

  def test_parse_rows_refuses_ragged_and_oversized_sprites
    assert_equal [[nil, "#"], ["#", nil]], D.parse_rows([".#", "#."])
    assert_raises(ArgumentError) { D.parse_rows([".#", "#"]) }
    assert_raises(ArgumentError) { D.parse_rows(["." * 10]) }
    assert_raises(ArgumentError) { D.parse_rows(Array.new(10, ".")) }
    assert_raises(ArgumentError) { D.parse_rows([]) }
    assert_raises(ArgumentError) { D.parse_rows("..#") }
    assert_raises(ArgumentError) { D.parse_rows([1, 2]) }
  end

  def test_sprite_lookup_prefers_bot_then_status_then_generated
    own = { "rows" => ["#"], "palette" => { "#" => "#111111" } }
    working = { "rows" => ["##"], "palette" => { "#" => "#222222" } }
    art = { "bots" => { "george" => own, "Bot Ops" => { "image" => "bot-ops.png" } }, "status" => { "Working" => working } }
    assert_equal own, D.sprite_for(art, "George", "working"), "the bot's own, any case"
    assert_equal working, D.sprite_for(art, "Bot Ops", "working"), "an image-only entry has nothing to draw, so the status sprite"
    assert_equal D.identicon("Bot Ops", body: "#30C8FC"), D.sprite_for(art, "Bot Ops", "idle", body: "#30C8FC")
    assert_equal D.identicon("Nobody"), D.sprite_for(nil, "Nobody", "error")
  end

  def test_dot_grid_draws_rows_times_cols_circles
    scene = BotOps::Scene.new(BotOps::Store.new, BotOps::PreviewHost.new)
    c = BotOps::Canvas.new(100, 100)
    scene.instance_variable_set(:@c, c)
    cells = [[[1, 2, 3, 1.0], nil, [1, 2, 3, 1.0]], [nil, [1, 2, 3, 1.0], nil]]
    scene.dot_grid(0, 0, cells, d: 4, gap: 1.5, glow: false)
    assert_equal 6, c.count(:circle)
    first, second = c.cmds.first(2)
    assert_equal [2.0, 2.0, 2.0], first.a[0, 3]
    assert_equal [7.5, 2.0], second.a[0, 2], "pitch is d + gap"
    assert_equal BotOps::Theme.rgba(BotOps::Theme.dot_off, 0.55), second.a[3], "unlit cells still show, faintly"
    c = BotOps::Canvas.new(100, 100)
    scene.instance_variable_set(:@c, c)
    scene.dot_grid(0, 0, cells, d: 4, gap: 1.5, glow: true)
    assert_equal 3 + 3 * 3, c.count(:circle), "a lit glowing cell is two halo rings and the dot"
  end

  def test_dot_sprite_maps_palette_and_dims
    scene = BotOps::Scene.new(BotOps::Store.new, BotOps::PreviewHost.new)
    c = BotOps::Canvas.new(100, 100)
    scene.instance_variable_set(:@c, c)
    scene.dot_sprite(0, 0, { "rows" => ["#o."], "palette" => { "#" => "cyan", "o" => "#FF0000" } }, d: 4, gap: 1, dim: true, glow: false)
    fills = c.cmds.map { |cmd| cmd.a[3] }
    assert_equal BotOps::Theme.rgba(BotOps::Theme.cyan, 0.5), fills[0]
    assert_equal [255, 0, 0, 0.5], fills[1]
    assert_equal BotOps::Theme.rgba(BotOps::Theme.dot_off, 0.3), fills[2]
  end

  def test_working_dots_pulse_on_odd_seconds
    scene = BotOps::Scene.new(BotOps::Store.new, BotOps::PreviewHost.new)
    count = lambda do |sec|
      c = BotOps::Canvas.new(300, 100)
      scene.instance_variable_set(:@c, c)
      Time.stub(:now, Time.at(sec)) { scene.dot_strip(0, 0, %w[ended error working], d: 6, gap: 3, cols: 24) }
      c.count(:circle)
    end
    even = count.(1000)
    odd = count.(1001)
    assert_equal 24 + 2, even, "one row: 24 cells, the working one drawn as three circles"
    assert_equal even + 1, odd, "an extra halo on odd seconds"
    c = BotOps::Canvas.new(300, 100)
    scene.instance_variable_set(:@c, c)
    h = scene.dot_strip(0, 0, Array.new(30, "ended"), d: 6, gap: 3, cols: 24)
    assert_equal 48, c.count(:circle), "two rows, the second padded with unlit cells"
    assert_equal 15, h
    c = BotOps::Canvas.new(300, 100)
    scene.instance_variable_set(:@c, c)
    Time.stub(:now, Time.at(1000)) { scene.dot_strip(0, 0, %w[ended error stale], d: 6, gap: 3, cols: 3) }
    assert_equal [BotOps::Theme.slate, BotOps::Theme.red, BotOps::Theme.yellow].map { |h| BotOps::Theme.rgba(h) }, c.cmds.map { |cmd| cmd.a[3] },
                 "coloured by the theme's status table: Ended, Error, Stale"
  end

  def test_bots_page_stays_within_op_budget
    Dir.mktmpdir do |dir|
      feed = BotOps::BotFeed.new(log: File.join(dir, "b.jsonl"))
      now = Time.now.to_f
      10.times do |b|
        96.times do |i|
          at = now - 86_000 + i * 890 + b
          feed.ingest({ "bot" => "bot-#{b}", "bot_event" => "run_start", "run_id" => "r#{b}_#{i}", "routine" => "r", "at" => at })
          feed.ingest({ "bot" => "bot-#{b}", "bot_event" => i.odd? ? "run_end" : "run_error", "run_id" => "r#{b}_#{i}", "error" => "x", "at" => at + 30 }) unless i == 95
        end
      end
      store = BotOps::Store.new.apply(type: "snapshot", snapshot: feed.snapshot, local: false)
      store.page = :bots
      scene = BotOps::Scene.new(store, BotOps::PreviewHost.new)
      scene.resize(1820, 1200)
      c = scene.build
      assert_equal 10, store.bots.size
      assert_operator c.count, :<, 6000, "the Bots page with ten full bots"
    end
  end
end
