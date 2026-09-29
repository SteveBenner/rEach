require "json"
require "time"
require "fileutils"
require "securerandom"

module Reach
  module Hands
    ROUTE = "/api/v1/hands"
    POLL_INTERVAL_S = 60

    class << self
      def raise_hand(trigger:, summary:, slice:, include_profile: false)
        workspace = resolve_workspace(slice)
        meta = Reach::Workspace.metadata(workspace)
        install = Reach::Enroll.current
        raise Reach::Refused, Reach::Messages.text("M-GATE-NOENROLL") unless install

        bundle = build_bundle(workspace, meta, trigger, summary, include_profile)
        tar_bytes = Reach::Tarball.write("bundle.json" => JSON.generate(bundle))
        envelope = seal_hand(install, meta, tar_bytes)
        idempotency_key = SecureRandom.uuid
        body = {
          "cutout_id" => meta["cutout_id"],
          "slice" => meta["slice"],
          "trigger" => trigger.to_s,
          "summary" => truncate_summary(summary.to_s),
          "bundle" => envelope
        }
        outbox_path = write_outbox(idempotency_key, ROUTE, body)

        begin
          response = client(install).post_json(ROUTE, body, idempotency_key: idempotency_key)
          result = response.json || {}
          FileUtils.rm_f(outbox_path)
          record_open_hand(result["hand_id"]) if result["hand_id"]
          result["hand_id"]
        rescue Reach::RemoteRefused
          FileUtils.rm_f(outbox_path)
          nil
        rescue Reach::Offline, Reach::NetworkError
          nil
        end
      end

      def status(hand_id)
        install = Reach::Enroll.current
        return { state: "unknown", reply: nil } unless install

        response = client(install).get("/api/v1/hands/#{hand_id}")
        body = response.json || {}
        { state: body["state"], reply: body["reply"] }
      rescue Reach::NetworkError, Reach::Offline
        { state: "unknown", reply: nil }
      end

      def list
        open_hands.map { |hand_id, reply| { hand_id: hand_id, reply: reply } }
      end

      def poll_replies
        changed = []
        state = open_hands
        state.each do |hand_id, record|
          record = record.is_a?(Hash) ? record : { "reply" => record, "polled_at" => nil }
          next if record["polled_at"] && (Time.now.utc - Time.parse(record["polled_at"])) < POLL_INTERVAL_S

          current = status(hand_id)
          update_open_hand(hand_id, current[:reply], Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
          if current[:reply] && current[:reply] != record["reply"]
            changed << { hand_id: hand_id, state: current[:state], reply: current[:reply] }
          end
          remove_open_hand(hand_id) if %w[resolved closed].include?(current[:state].to_s)
        end
        changed
      end

      private

      def resolve_workspace(slice)
        return slice if slice.is_a?(String) && File.directory?(File.join(slice, ".reach"))

        slices = Reach::Workspace.current_slices
        match = slices.find { |path| File.basename(path) == slice.to_s }
        suffixed = slices.select { |path| File.basename(path).end_with?("-#{slice}") }
        match ||= suffixed.first if suffixed.size == 1
        raise Reach::Refused, "reach: no workspace found for slice #{slice.inspect}" unless match

        match
      end

      def build_bundle(workspace, meta, trigger, summary, include_profile)
        owned = Array(meta["owned_files"])
        files = {}
        owned.each do |relative_path|
          full_path = File.join(workspace, relative_path)
          files[relative_path] = File.file?(full_path) ? File.read(full_path) : nil
        end

        profile = nil
        if include_profile && defined?(Reach::Profile)
          begin
            profile = Reach::Profile.load["fields"]
          rescue StandardError
            profile = nil
          end
        end

        {
          "schema" => "reach.hand/v1",
          "trigger" => trigger.to_s,
          "summary" => summary.to_s,
          "course" => meta["course"],
          "assignment" => meta["assignment"],
          "cutout_id" => meta["cutout_id"],
          "slice" => meta["slice"],
          "attempts" => recent_attempts(meta["slice"]),
          "files" => files,
          "plan" => Reach::Plan.load(workspace),
          "profile" => profile,
          "client_created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
      end

      def truncate_summary(text)
        bytes = text.dup.force_encoding(Encoding::UTF_8)
        return bytes if bytes.bytesize <= 2000

        result = +""
        bytes.each_char do |char|
          break if (result.bytesize + char.bytesize) > 2000

          result << char
        end
        result
      end

      def recent_attempts(slice)
        records = Reach::Corpus.new(Reach.ports).recent("attempt", limit: 100)
        records.select { |record| record["slice"] == slice }
      rescue StandardError
        []
      end

      def seal_hand(install, meta, tar_bytes)
        encryption_key = install.fetch("encryption_key")
        header = {
          "schema" => "teach.package/v1",
          "kind" => "hand_bundle",
          "id" => "renv_#{SecureRandom.hex(10)}",
          "version" => 1,
          "course" => meta["course"],
          "assignment" => meta["assignment"],
          "student_id" => install["student_id"],
          "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
          "signing_key_id" => install["install_id"],
          "recipient_key_id" => encryption_key["key_id"]
        }
        Reach::Crypto.seal(
          header: header,
          plaintext: tar_bytes,
          recipient_public_key: Reach::Crypto.load_public_key(encryption_key["pem"]),
          signer_private_key: Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
        )
      end

      def write_outbox(idempotency_key, route, body)
        FileUtils.mkdir_p(Reach::Paths.outbox_dir)
        path = File.join(Reach::Paths.outbox_dir, "#{idempotency_key}.json")
        File.write(path, JSON.generate("kind" => "hand", "route" => route, "idempotency_key" => idempotency_key, "body" => body))
        path
      end

      def client(install)
        Reach::Client.for_install(install)
      end

      def open_hands_file
        File.join(Reach::Paths.home, "hands", "open.json")
      end

      def open_hands
        return {} unless File.file?(open_hands_file)

        JSON.parse(File.read(open_hands_file))
      rescue JSON::ParserError
        {}
      end

      def record_open_hand(hand_id)
        state = open_hands
        state[hand_id] = { "reply" => nil, "polled_at" => nil }
        write_open_hands(state)
      end

      def update_open_hand(hand_id, reply, polled_at)
        state = open_hands
        state[hand_id] = { "reply" => reply, "polled_at" => polled_at }
        write_open_hands(state)
      end

      def remove_open_hand(hand_id)
        state = open_hands
        state.delete(hand_id)
        write_open_hands(state)
      end

      def write_open_hands(state)
        FileUtils.mkdir_p(File.dirname(open_hands_file))
        File.write(open_hands_file, JSON.generate(state))
      end
    end
  end
end
