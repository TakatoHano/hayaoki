# frozen_string_literal: true

require_relative "../test_helper"
require "hayaoki/insitu/clock"

class InsituClockTest < Minitest::Test
  C = Hayaoki::Insitu::Clock
  STAT = "42 (ruby) S 1 42 42 0 -1 0 0 0 0 0 150 30 0 0 20 0 5 0 500 1 1 1\n"

  def test_now_is_monotonic_float
    a = C.now_ms
    assert_kind_of Float, a
    assert_operator C.now_ms, :>=, a
  end

  def test_since_start
    assert_equal 30, C.since_start(130, 100)
    assert_nil C.since_start(nil, 100)
    assert_nil C.since_start(90, 100)
    assert_nil C.since_start(90, nil)
  end

  def test_start_at
    assert_equal "2026-11-08T03:12:45.120Z",
      C.start_at(1000.0, boot_now: 3000.0, real_now: Time.utc(2026, 11, 8, 3, 12, 47, 120_000).to_f * 1000)
    assert_nil C.start_at(nil)
  end

  def test_process_start_from_fixture
    skip "needs CLOCK_BOOTTIME" unless C.boottime?
    assert_equal 5000.0, C.process_start_ms(STAT, tck: 100, now: 9000.0)
    assert_nil C.process_start_ms(STAT, tck: 100, now: 4000.0) # in the future
    assert_nil C.process_start_ms("junk", tck: 100, now: 9000.0)
    assert_nil C.process_start_ms(STAT, tck: 0, now: 9000.0)
  end

  def test_process_start_real
    skip "needs Linux /proc" unless RUBY_PLATFORM.include?("linux")
    s = C.process_start_ms
    assert_operator s, :<=, C.now_ms
    assert_match(/\A\d{4}-\d\d-\d\dT.*Z\z/, C.start_at(s))
  end

  def test_unavailable_on_non_linux
    skip "Linux only" if RUBY_PLATFORM.include?("linux")
    assert_nil C.process_start_ms
  end
end
