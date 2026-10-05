require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require_relative "../../lib/reach"

class HarnessSourceCodexBinTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("reach-codex-bin")
    @saved = ENV.to_h.slice("PATH", "CODEX_CLI_PATH")
    ENV["PATH"] = File.join(@dir, "empty-path")
  end

  def teardown
    %w[PATH CODEX_CLI_PATH].each { |key| @saved.key?(key) ? ENV[key] = @saved[key] : ENV.delete(key) }
    FileUtils.remove_entry(@dir)
  end

  def cli_file(name)
    path = File.join(@dir, "bin", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
    path
  end

  def test_accepts_codex_and_codex_exe_in_any_case
    %w[codex codex.exe CODEX.EXE Codex].each do |name|
      ENV["CODEX_CLI_PATH"] = cli_file(name)
      assert_equal ENV["CODEX_CLI_PATH"], Reach::HarnessSource.codex_bin, name
    end
  end

  def test_rejects_other_file_names
    %w[evil.sh codex.sh codex.bat codex-old notcodex.exe].each do |name|
      ENV["CODEX_CLI_PATH"] = cli_file(name)
      assert_nil Reach::HarnessSource.codex_bin, name
    end
  end

  def test_rejects_missing_file_directory_and_empty_value
    ENV["CODEX_CLI_PATH"] = File.join(@dir, "missing", "codex")
    assert_nil Reach::HarnessSource.codex_bin
    FileUtils.mkdir_p(File.join(@dir, "dir", "codex"))
    ENV["CODEX_CLI_PATH"] = File.join(@dir, "dir", "codex")
    assert_nil Reach::HarnessSource.codex_bin
    ENV["CODEX_CLI_PATH"] = ""
    assert_nil Reach::HarnessSource.codex_bin
  end

  def test_accepts_windows_path_spelling
    ENV["CODEX_CLI_PATH"] = 'C:\Program Files\Codex\bin\0123456789abcdef\codex.exe'
    File.stub(:file?, true) do
      assert_equal ENV["CODEX_CLI_PATH"], Reach::HarnessSource.codex_bin
    end
    ENV["CODEX_CLI_PATH"] = 'C:\Temp\payload.exe'
    File.stub(:file?, true) do
      assert_nil Reach::HarnessSource.codex_bin
    end
  end

  def test_codex_on_path_wins_over_the_variable
    bin = File.join(@dir, "path-bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "codex"), "")
    File.chmod(0o755, File.join(bin, "codex"))
    ENV["PATH"] = bin
    ENV["CODEX_CLI_PATH"] = cli_file("evil.sh")
    assert_equal "codex", Reach::HarnessSource.codex_bin
  end
end
