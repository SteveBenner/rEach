require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"
require_relative "../release_stable"

class ReleaseStableTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("reach-release-stable")
    @origin = File.join(@dir, "github.com", "owner", "repo.git")
    @work = File.join(@dir, "work")
    FileUtils.mkdir_p(File.dirname(@origin))
    git(@dir, "init", "--quiet", "--bare", "--initial-branch=main", @origin)
    git(@dir, "clone", "--quiet", @origin, @work)
    @first = commit("first")
    git(@work, "push", "--quiet", "origin", "HEAD:refs/heads/main")
    @saved_root = ReleaseStable::ROOT
    swap_root(@work)
    self.latest = "v9.9.1"
  end

  def teardown
    swap_root(@saved_root)
    ReleaseStable.singleton_class.send(:remove_method, :latest_tag)
    FileUtils.remove_entry(@dir)
  end

  def swap_root(path)
    ReleaseStable.send(:remove_const, :ROOT)
    ReleaseStable.const_set(:ROOT, path)
  end

  def latest=(tag)
    ReleaseStable.singleton_class.send(:remove_method, :latest_tag) if ReleaseStable.singleton_class.instance_methods(false).include?(:latest_tag)
    ReleaseStable.define_singleton_method(:latest_tag) { |_name| tag }
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args, chdir: dir)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out.strip
  end

  def commit(message)
    git(@work, "commit", "--quiet", "--allow-empty", "-m", message)
    git(@work, "rev-parse", "HEAD")
  end

  def tag_and_push(name)
    git(@work, "tag", name)
    git(@work, "push", "--quiet", "origin", "refs/tags/#{name}")
  end

  def stable_on_origin
    out, _err, status = Open3.capture3("git", "rev-parse", "--verify", "--quiet", "refs/heads/stable", chdir: @origin)
    status.success? ? out.strip : nil
  end

  def run_tool(*argv)
    out = StringIO.new
    err = StringIO.new
    $stdout = out
    $stderr = err
    code = ReleaseStable.run(argv)
    [code, out.string, err.string]
  ensure
    $stdout = STDOUT
    $stderr = STDERR
  end

  def test_refuses_a_tag_that_is_not_latest
    git(@work, "push", "--quiet", "origin", "#{@first}:refs/heads/stable")
    commit("release")
    tag_and_push("v9.9.1")
    self.latest = "v9.9.0"
    code, _out, err = run_tool("v9.9.1")
    assert_equal 1, code
    assert_match(/not the Latest release/, err)
    assert_equal @first, stable_on_origin
  end

  def test_refuses_a_non_fast_forward_move
    side = commit("side")
    git(@work, "push", "--quiet", "origin", "#{side}:refs/heads/stable")
    git(@work, "reset", "--quiet", "--hard", @first)
    commit("release")
    tag_and_push("v9.9.1")
    code, _out, err = run_tool("v9.9.1")
    assert_equal 1, code
    assert_match(/not an ancestor/, err)
    assert_equal side, stable_on_origin
  end

  def test_dry_run_reports_and_pushes_nothing
    git(@work, "push", "--quiet", "origin", "#{@first}:refs/heads/stable")
    commit("release")
    tag_and_push("v9.9.1")
    code, out, _err = run_tool("v9.9.1", "--dry-run")
    assert_equal 0, code
    assert_match(/would move origin stable/, out)
    assert_equal @first, stable_on_origin
  end

  def test_moves_stable_forward_to_the_latest_tag
    git(@work, "push", "--quiet", "origin", "#{@first}:refs/heads/stable")
    release = commit("release")
    tag_and_push("v9.9.1")
    code, out, _err = run_tool("v9.9.1")
    assert_equal 0, code
    assert_match(/moved origin stable/, out)
    assert_equal release, stable_on_origin
    code, out, _err = run_tool("v9.9.1")
    assert_equal 0, code
    assert_match(/already at v9\.9\.1/, out)
  end

  def test_creates_stable_when_the_remote_has_none
    release = commit("release")
    tag_and_push("v9.9.1")
    code, out, err = run_tool("v9.9.1")
    assert_equal 0, code, err
    assert_match(/moved origin stable absent ->/, out)
    assert_equal release, stable_on_origin
  end

  def test_refuses_a_malformed_tag
    code, _out, err = run_tool("9.9.1")
    assert_equal 2, code
    assert_match(/usage/, err)
  end
end
