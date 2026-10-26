# frozen_string_literal: true

require "test_helper"
require "fileutils"

class ThemeTest < Minitest::Test
  T = BotOps::Theme

  def setup
    @user_dir = T.user_dir
    FileUtils.mkdir_p(@user_dir)
  end

  def teardown
    T.use(T::DEFAULT)
    FileUtils.rm_rf(@user_dir)
  end

  def write_theme(slug, yaml)
    path = File.join(@user_dir, "#{slug}.yml")
    File.write(path, yaml)
    path
  end

  # Clicks the first clickable text +text+ on +canvas+.
  def click_text(scene, canvas, text)
    cmd = canvas.cmds.find { |c| c.op == :text && c.a[0] == text && canvas.hit_at(c.a[1] + 2, c.a[2] + 2) }
    refute_nil cmd, "no clickable text #{text.inspect}"
    assert scene.click(cmd.a[1] + 2, cmd.a[2] + 2)
  end

  def test_standard_blue_defines_every_colour_and_role
    s = T.standard
    assert_equal "Standard Blue", s.name
    assert_equal "standard-blue", s.slug
    T::KEYS.each { |k| assert_match T::HEX, s[k], k.to_s }
    assert_equal "#30C8FC", T.cyan
    assert_equal T.green, T.status_color("Busy")
    assert_equal T.muted, T.status_color("Whatever")
    assert_equal T.red, T.priority_color("High")
    assert_equal T.yellow, T.level_color("WARN")
    assert_equal [0x30, 0xC8, 0xFC, 0.5], T.rgba(T.cyan, 0.5)
  end

  def test_a_theme_fills_in_from_standard_blue_and_may_name_colours
    write_theme("ember", "name: Ember\ncolors:\n  cyan: '#ff8800'\n  bolt: cyan\nstatus:\n  Busy: bolt\n")
    assert T.use("ember")
    assert_equal "Ember", T.current.name
    assert_equal "#FF8800", T.cyan
    assert_equal "#FF8800", T.bolt
    assert_equal "#FF8800", T.status_color("Busy")
    assert_equal T.standard.yellow, T.status_color("Pending"), "the other rows come from Standard Blue"
    assert_equal T.standard.text, T.text, "unmentioned colours come from Standard Blue"
    assert_equal "standard-blue", T.available.first.first, "Standard Blue is listed first"
    assert_includes T.available.map { |_, name, _| name }, "Ember"
  end

  def test_a_broken_theme_is_refused_and_the_current_one_stays
    write_theme("bad-hex", "colors:\n  cyan: blueish\n")
    write_theme("bad-key", "colors:\n  cyans: '#000000'\n")
    write_theme("loop", "colors:\n  cyan: teal\n  teal: cyan\n")
    write_theme("not-yaml", "colors: [\n")
    before = T.current
    _, err = capture_io do
      %w[bad-hex bad-key loop not-yaml missing].each { |slug| refute T.use(slug), slug }
    end
    assert_same before, T.current
    assert_match(/blueish/, err)
    assert_match(/cyans/, err)
    assert_match(/refers to itself/, err)
    assert_match(/no theme "missing"/, err)
  end

  def test_the_scene_draws_with_the_selected_theme
    write_theme("night", "colors:\n  bg: '#112233'\n")
    scene = BotOps::Scene.new(Fixtures.store, BotOps::PreviewHost.new)
    assert T.use("night")
    first = scene.build.cmds.first
    assert_equal :rect, first.op
    assert_equal [0x11, 0x22, 0x33, 1.0], first.a[4]
    assert_equal [0x11, 0x22, 0x33], JSON.parse(scene.build.to_json(bg: T.hex_rgb(T.bg)))["bg"]
  end

  def test_the_settings_page_picks_a_theme_and_remembers_it
    write_theme("ember", "name: Ember\ncolors:\n  cyan: '#ff8800'\n")
    store = Fixtures.store
    scene = BotOps::Scene.new(store, BotOps::PreviewHost.new)
    store.page = :settings
    c = scene.build
    assert_includes c.texts, "Standard Blue"
    refute_includes c.texts, "Ember", "the list is closed"
    click_text(scene, c, "Standard Blue")
    assert scene.theme_menu?
    c = scene.build
    assert_includes c.texts, "Ember"
    click_text(scene, c, "Ember")
    refute scene.theme_menu?
    assert_equal "ember", store.theme
    assert_equal "Ember", T.current.name
    assert_equal "#FF8800", T.cyan

    click_text(scene, scene.build, "Ember")
    assert scene.theme_menu?
    assert scene.key(BotOps::Scene::KEY_ESC), "Esc closes the list"
    refute scene.theme_menu?
    click_text(scene, scene.build, "Ember")
    scene.build
    assert scene.click(5, 5), "so does a click anywhere else"
    refute scene.theme_menu?
    assert_equal "ember", store.theme
  end

  def test_a_theme_file_edited_while_running_reloads
    path = write_theme("live", "colors:\n  cyan: '#111111'\n")
    assert T.use("live")
    assert_equal "#111111", T.cyan
    File.write(path, "colors:\n  cyan: '#222222'\n")
    later = Time.now + 5
    File.utime(later, later, path)
    assert T.reload_if_changed
    assert_equal "#222222", T.cyan
    refute T.reload_if_changed
  end

  def test_new_colour_keys_resolve
    assert_equal "#16305E", T.dot_off
    assert_equal T.cyan, T.dot_lit
    assert_equal T.green, T.status_color("Working")
    assert_equal T.yellow, T.status_color("Stale")
    write_theme("dotty", "colors:\n  dot_off: '#101010'\n  dot_lit: yellow\n")
    assert T.use("dotty")
    assert_equal ["#101010", T.standard.yellow], [T.dot_off, T.dot_lit]
  end

  def test_art_section_is_optional
    write_theme("plain", "colors:\n  cyan: '#ff8800'\n")
    assert T.use("plain")
    assert_equal T.standard.art, T.art, "inherited whole from Standard Blue"
    assert_equal({ "off" => "#16305E", "off_alpha" => 0.55, "glow" => true }, T.art["dot"])
    assert_equal({}, T.art["bots"])
    assert T.art.frozen?
  end

  def test_art_sprites_load_and_inherit_per_key
    write_theme("faces", <<~YAML)
      art:
        dot: { glow: false }
        status:
          Working: { palette: { "#": green, "o": pink }, rows: ["..#..", ".o#o.", "#####"] }
        bots:
          "George": { palette: { "#": "#123456" }, rows: ["#.#", ".#.", "#.#"] }
    YAML
    assert T.use("faces")
    assert_equal({ "off" => "#16305E", "off_alpha" => 0.55, "glow" => false }, T.art["dot"], "dot settings merge over the base")
    assert_equal({ "#" => T.standard.green, "o" => T.standard.pink }, T.art["status"]["Working"]["palette"], "palette colours resolve like colours")
    assert_equal ["#.#", ".#.", "#.#"], T.art["bots"]["George"]["rows"]
    assert_equal T.art["bots"]["George"], BotOps::DotArt.sprite_for(T.art, "george", "idle")
    assert_equal T.art["status"]["Working"], BotOps::DotArt.sprite_for(T.art, "Bot Ops", "working")
  end

  def test_art_sprite_rows_must_be_rectangular
    write_theme("ragged", "art:\n  bots:\n    George: { palette: { '#': cyan }, rows: ['##', '#'] }\n")
    write_theme("huge", "art:\n  bots:\n    George: { palette: { '#': cyan }, rows: ['##########'] }\n")
    write_theme("norows", "art:\n  bots:\n    George: { palette: { '#': cyan } }\n")
    before = T.current
    _, err = capture_io { %w[ragged huge norows].each { |slug| refute T.use(slug), slug } }
    assert_same before, T.current
    assert_match(/art\.bots\.George\.rows must be strings of equal length/, err)
    assert_match(/art\.bots\.George\.rows may be at most 9 x 9/, err)
    assert_match(/art\.bots\.George needs `rows`/, err)
  end

  def test_art_palette_must_use_known_colours
    write_theme("badcol", "art:\n  status:\n    Error: { palette: { '#': crimson }, rows: ['#'] }\n")
    write_theme("nopal", "art:\n  status:\n    Error: { palette: { '#': red }, rows: ['#x'] }\n")
    write_theme("badalpha", "art:\n  dot: { off_alpha: 3 }\n")
    _, err = capture_io { %w[badcol nopal badalpha].each { |slug| refute T.use(slug), slug } }
    assert_match(/art\.status\.Error\.palette\.# is "crimson"/, err)
    assert_match(/art\.status\.Error\.rows uses "x", not in its palette/, err)
    assert_match(/art\.dot\.off_alpha is 3/, err)
  end

  def test_art_image_field_is_reserved_and_ignored
    write_theme("pics", "art:\n  bots:\n    'Bot Ops': { image: bot-ops.png }\n    George: { image: g.png, palette: { '#': cyan }, rows: ['#'] }\n")
    assert T.use("pics")
    assert_equal({ "image" => "bot-ops.png" }, T.art["bots"]["Bot Ops"])
    assert_equal "g.png", T.art["bots"]["George"]["image"]
    assert_equal BotOps::DotArt.identicon("Bot Ops", body: T.cyan), BotOps::DotArt.sprite_for(T.art, "Bot Ops", "idle", body: T.cyan),
                 "nothing is drawn from an image yet"
    assert_equal ["#"], BotOps::DotArt.sprite_for(T.art, "George", "idle")["rows"]
  end

  def test_prefs_remember_the_theme
    store = BotOps::Store.new
    assert_equal "standard-blue", store.theme
    store.theme = "ember"
    assert_equal "ember", store.theme
  end
end
