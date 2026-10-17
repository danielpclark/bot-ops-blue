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

  def test_prefs_remember_the_theme
    store = BotOps::Store.new
    assert_equal "standard-blue", store.theme
    store.theme = "ember"
    assert_equal "ember", store.theme
  end
end
