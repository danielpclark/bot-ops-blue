# frozen_string_literal: true

require "test_helper"
require "net/http"
require "yaml"
require "tmpdir"

class CollectorBotEventTest < Minitest::Test
  TOKEN = "collector-bot-token-123456"

  def setup
    @got = Queue.new
    @dir = Dir.mktmpdir
    cloud = BotOps::CloudFeed.new(log: File.join(@dir, "cloud-events.jsonl"))
    @collector = BotOps::Collector.new("127.0.0.1:0", TOKEN, on_event: ->(e) { cloud.ingest(e) },
                                                             on_bot_event: ->(e) { @got << e; e.is_a?(Hash) && e["bot_event"] == "run_start" }) { |_| }.start
    host, port = @collector.address.split(":")
    @http = Net::HTTP.new(host, Integer(port))
  end

  def teardown
    @collector.stop
    FileUtils.remove_entry(@dir)
  end

  def post(path, body, auth: nil)
    req = Net::HTTP::Post.new(path, "Content-Type" => "application/json")
    req["Authorization"] = auth if auth
    req.body = body.is_a?(String) ? body : JSON.generate(body)
    @http.request(req)
  end

  def basic
    "Basic " + ["botops:#{TOKEN}"].pack("m0")
  end

  def event
    { "bot" => "Bot Ops", "bot_event" => "run_start", "run_id" => "r_1", "routine" => "smoke" }
  end

  def test_bot_events_need_the_token_in_either_form
    assert_equal "401", post("/v1/bot-event", event).code
    assert_equal "401", post("/v1/bot-event", event, auth: "Basic " + ["botops:wrong"].pack("m0")).code
    assert_equal "204", post("/v1/bot-event", event, auth: basic).code
    assert_equal "204", post("/v1/bot-event", event, auth: "Bearer #{TOKEN}").code
    assert_equal event, @got.pop(timeout: 2)
    assert_equal event, @got.pop(timeout: 2)
  end

  def test_a_body_that_is_not_a_bot_event_is_refused
    res = post("/v1/bot-event", { "hello" => "world" }, auth: basic)
    assert_equal "422", res.code
    assert_equal "not a bot event", res.body
    assert_equal "400", post("/v1/bot-event", "{not json", auth: basic).code
    assert_equal "422", post("/v1/event", event, auth: basic).code, "a bot event is not a hook event"
  end

  def test_a_batch_is_accepted_when_any_event_is
    assert_equal "204", post("/v1/bot-event", { "events" => [{ "x" => 1 }, event] }, auth: basic).code
    assert_equal 2, 2.times.count { @got.pop(timeout: 2) }
    assert_equal "422", post("/v1/bot-event", { "events" => [{ "x" => 1 }] }, auth: basic).code
    assert_equal "422", post("/v1/bot-event", { "events" => [] }, auth: basic).code
  end

  def test_bot_events_are_404_when_nothing_takes_them
    plain = BotOps::Collector.new("127.0.0.1:0", TOKEN) { |_| }.start
    host, port = plain.address.split(":")
    req = Net::HTTP::Post.new("/v1/bot-event", "Content-Type" => "application/json", "Authorization" => basic)
    req.body = JSON.generate(event)
    res = Net::HTTP.new(host, Integer(port)).request(req)
    assert_equal ["404", "bot events not enabled"], [res.code, res.body]
  ensure
    plain&.stop
  end

  def test_ngrok_policy_template_allows_bot_events
    path = File.expand_path("../cloud/ngrok-policy.example.yml", __dir__)
    policy = YAML.safe_load(File.read(path))
    expr = policy["on_http_request"].first["expressions"].first
    assert_includes expr, "'/v1/bot-event'"
    assert_includes expr, "'/v1/event'"
    # rake ngrok:policy only swaps the token and the header comment, so the
    # generated file keeps the same path list.
    rake = File.read(File.expand_path("../Rakefile", __dir__))
    subs = rake[/task policy: :token do(.*?)^  end/m, 1].scan(/\.sub\(/).size
    assert_equal 2, subs, "only the token and the comment are substituted"
  end
end
