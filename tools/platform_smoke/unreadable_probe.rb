# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require "reach"

class ProbeFailure < StandardError; end

def expect(label, condition, detail = nil)
  raise ProbeFailure, "#{label}#{detail ? ": #{detail}" : ''}" unless condition
end

key = Reach::Crypto.generate_install_key
FileUtils.mkdir_p(File.dirname(Reach::Paths.install_key_file))
File.write(Reach::Paths.install_key_file, key.to_pem)
document = Reach::Fingerprint.build(install_public_key: key.public_key, harness: "terminal", enrolled_via: "smoke", salt: "s" * 32)
Reach::Fingerprint.store!(document)

real_reader = Reach::Fingerprint.method(:run_reader)
real_linux = Reach::Fingerprint.method(:linux_machine_id)
real_machine = Reach::Fingerprint.method(:machine_id)
dropped = 0

class << Reach::Enroll
  def current
    { "install_id" => "smoke-install" }
  end

  def replaced?(_install)
    false
  end
end

stamp = { "stamp_id" => "smoke-stamp", "fingerprint_digest" => document["digest"], "fingerprint_strict_digest" => document["strict_digest"] }
Reach::Stamp.define_singleton_method(:current) { stamp }
Reach::Stamp.define_singleton_method(:expired?) { |_stamp| false }
Reach::Stamp.define_singleton_method(:drop!) { dropped += 1 }
Reach::EnrollmentLock.define_singleton_method(:stamp_valid?) { |_install, _stamp| true }

use = lambda do |mode|
  Reach::Fingerprint.define_singleton_method(:run_reader, real_reader)
  Reach::Fingerprint.define_singleton_method(:linux_machine_id, real_linux)
  Reach::Fingerprint.define_singleton_method(:machine_id, real_machine)
  case mode
  when :unreadable
    Reach::Fingerprint.define_singleton_method(:run_reader) { |*_command, **_options| "" }
    Reach::Fingerprint.define_singleton_method(:linux_machine_id) { nil }
  when :different
    Reach::Fingerprint.define_singleton_method(:machine_id) { "another-computer" }
  end
  Reach::Fingerprint.clear_cache!
end

unreadable_file = Reach::Paths.enroll_unreadable_file
moved_file = Reach::Paths.enroll_moved_file

use.call(:real)
expect("a readable probe locks nothing", Reach::EnrollmentLock.reason_for_state.nil? && !File.file?(unreadable_file) && !File.file?(moved_file))

use.call(:unreadable)
expect("the probe really fails", Reach::Fingerprint.machine_id == Reach::Fingerprint::UNKNOWN)
expect("an unreadable probe does not lock", Reach::EnrollmentLock.reason_for_state.nil?)
expect("the stamp is kept", dropped.zero?)
expect("the unreadable observation is recorded", File.file?(unreadable_file) && !File.file?(moved_file))
expect("the unreadable value is not cached", !File.file?(Reach::Paths.fingerprint_cache_file))
first = JSON.parse(File.read(unreadable_file))
expect("the changed list names the machine id", first["changed"] == ["machine_id"], first["changed"].inspect)
sleep 1.1
expect("a second unreadable check still does not lock", Reach::EnrollmentLock.reason_for_state.nil?)
expect("the first observation time is kept", JSON.parse(File.read(unreadable_file))["since"] == first["since"])

old = (Time.now.utc - (Reach::EnrollmentLock::UNREADABLE_GRACE_S + 3600)).strftime("%Y-%m-%dT%H:%M:%SZ")
File.write(unreadable_file, JSON.generate("since" => old, "changed" => ["machine_id"]))
expect("past the grace it locks as moved", Reach::EnrollmentLock.reason_for_state == "moved" && File.file?(moved_file) && dropped == 1)
Reach::EnrollmentLock.clear_moved!
expect("clearing the lock clears the observation", !File.file?(moved_file) && !File.file?(unreadable_file))

use.call(:different)
expect("a readable different machine locks at once", Reach::EnrollmentLock.reason_for_state == "moved" && !File.file?(unreadable_file))
Reach::EnrollmentLock.clear_moved!

use.call(:unreadable)
Reach::EnrollmentLock.reason_for_state
use.call(:real)
expect("a readable probe after an unreadable one locks nothing", Reach::EnrollmentLock.reason_for_state.nil? && !File.file?(unreadable_file))

begin
  Reach::Validation.harness("claude-desktop")
  expect("an unsupported harness is refused", false)
rescue Reach::Refused => e
  expect("the refusal keeps its text", e.message.start_with?(Reach::Validation::BLOCKED))
  expect("the refusal names its cause", e.message.end_with?("(cause: harness_label:claude-desktop)"), e.message[-60..])
end

puts "unreadable probe: grace, lock after grace, readable mismatch and validation cause all held"
