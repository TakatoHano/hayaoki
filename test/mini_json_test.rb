# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "hayaoki/mini_json"

class MiniJSONTest < Minitest::Test
  def enc(v) = Hayaoki::MiniJSON.encode(v)

  def test_nested_hash_and_array
    v = { "a" => { "b" => [1, [2, 3], {}], "c" => [] }, "d" => [{ "e" => nil }] }
    assert_equal '{"a":{"b":[1,[2,3],{}],"c":[]},"d":[{"e":null}]}', enc(v)
    assert_equal v, JSON.parse(enc(v))
  end

  def test_strings_with_escapes_and_control_chars
    assert_equal '"say \"hi\""', enc('say "hi"')
    assert_equal '"a\\\\b"', enc("a\\b")
    assert_equal '"l1\nl2\tx\r"', enc("l1\nl2\tx\r")
    assert_equal '"\u0001\u001f"', enc("\u0001\u001f")
    assert_equal "\"a\\u0000b\"", enc("a\u0000b")
  end

  def test_unicode_passes_through
    assert_equal "\"日本語 \u{1F600}\"", enc("日本語 \u{1F600}")
    assert_equal "\"日本\"", enc("日本".b.force_encoding("UTF-8"))
  end

  def test_invalid_utf8_is_scrubbed
    out = enc("ok\xE3\x81".dup.force_encoding("UTF-8"))
    assert_equal "ok�", JSON.parse(out)
  end

  def test_nil_true_false_and_symbols
    assert_equal "null", enc(nil)
    assert_equal "true", enc(true)
    assert_equal "false", enc(false)
    assert_equal '"value"', enc(:value)
    assert_equal '{"k":"v"}', enc({ k: :v })
  end

  def test_integers_and_floats
    assert_equal "0", enc(0)
    assert_equal "-42", enc(-42)
    assert_equal "12345678901234567890", enc(12_345_678_901_234_567_890)
    assert_equal "3.5", enc(3.5)
    assert_equal "null", enc(Float::INFINITY)
    assert_equal "null", enc(Float::NAN)
    assert_equal "[1,-2,3]", enc([1, -2, 3])
  end

  def test_other_objects_fall_back_to_to_s
    assert_equal '"Object"', enc(Object)
  end
end
