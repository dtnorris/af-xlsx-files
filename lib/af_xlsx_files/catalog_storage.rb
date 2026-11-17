# frozen_string_literal: true

require "open3"

module AfXlsxFiles
  module Internal
    # Storage for the pipeline's reviewed catalog workflow. The pipeline supplies
    # its admitted snapshot and runs its own policy checks while the root is locked.
    class CatalogStorage
      # Bind one raw manifest observation to its parsed, validated role state.
      class Manifest < ProjectState
        attr_reader :bytes

        # Read exact manifest bytes unless a historical observation supplies them.
        # An absent manifest raises Error and other read errors propagate.
        def initialize(manifest_path:, bytes: nil)
          super(manifest_path:)
          @bytes = (bytes || read_current).freeze
        end

        # Return the hash and size of the bytes used for validation.
        def binding
          {"sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize}
        end

        # Return all validated role identities. Invalid role or workbook data raises Error.
        def roles
          ROLES.to_h { |name| [name, resolve(name).to_h.slice(:version, :filename, :sha256, :bytes).transform_keys(&:to_s)] }
        end

        # Return the serialized one-role transition after validating the proposed
        # workbook and unchanged independent roles. Invalid state raises Error.
        def promoted_bytes(candidate)
          version = candidate.fetch("version")
          current = resolve("catalog_head").version
          if compare_versions(version, current).negative?
            raise Error, "catalog_head cannot move backward from #{current} to #{version}"
          end

          document = @data.merge("catalog_head" => candidate)
          validate_data!(document)
          YAML.dump(document)
        end

        # Reject attempts by historical consumers to write through this read view.
        def promote!(**)
          raise ValidationError, "historical catalog observations are read-only"
        end

        private

        # Parse the bound bytes using the v0.2 manifest representation.
        # Invalid YAML or a nonmapping document raises Error.
        def load_data
          raw = YAML.safe_load(bytes, aliases: false)
          raise Error, "project-state manifest must contain a mapping" unless raw.is_a?(Hash)
          stringify_keys(raw)
        rescue Psych::Exception => error
          raise Error, "invalid project-state YAML: #{error.message}"
        end

        # Read the named manifest or raise Error if it is absent.
        def read_current
          raise Error, "missing project-state manifest: #{manifest_path}" unless File.file?(manifest_path)
          File.binread(manifest_path)
        end
      end
      private_constant :Manifest

      # Historical read view for the one manifest involved in an exact replay.
      class Replay
        # Verify reviewed Git bytes, role bindings and exact live transition.
        # Invalid or changed replay observations raise ValidationError.
        def initialize(snapshot:, historical_binding:)
          @path = File.expand_path(snapshot.manifest_path)
          check!(historical_binding.is_a?(Hash) && historical_binding["path"] == @path,
                 "historical catalog manifest locator differs from review")
          root = File.realpath(snapshot.repository_root)
          check!(File.dirname(File.realpath(@path)) == root, "replay catalog root differs from review")
          check!(CatalogStorage.git!(root, "rev-parse", "HEAD").strip == snapshot.repository_head &&
                 CatalogStorage.git_origin(root) == snapshot.repository_remote,
                 "replay catalog repository changed after review")
          check!(snapshot.repository_head.match?(/\A[0-9a-f]{40}\z/), "invalid reviewed catalog HEAD")
          bytes = CatalogStorage.git!(root, "show", "#{snapshot.repository_head}:#{File.basename(@path)}")
          @historical = Manifest.new(manifest_path: @path, bytes:)
          check!(@historical.binding == historical_binding.slice("sha256", "bytes"),
                 "historical catalog manifest differs from the exact reviewed package")
          @historical.validate!
          check!(@historical.roles == snapshot.roles, "historical catalog roles differ from review")

          @destination = File.join(File.dirname(@path), snapshot.candidate.fetch("filename"))
          check!(File.expand_path(snapshot.destination) == @destination, "replay destination differs from reviewed catalog")
          @candidate_binding = snapshot.candidate.slice("sha256", "bytes").freeze
          @promoted_bytes = @historical.promoted_bytes(snapshot.candidate).freeze
          assert_current!
        rescue Error => error
          raise if error.is_a?(ValidationError)
          raise ValidationError, error.message
        end

        # Return whether this exact locator selects the reviewed manifest.
        def observes?(path)
          File.expand_path(path) == @path
        end

        # Return reviewed manifest identity after rechecking the live transition.
        def binding
          assert_current!
          @historical.binding
        end

        # Return a read-only manifest at its original locator after rechecking
        # the live transition. Other workflow inputs stay with the caller.
        def project_state
          assert_current!
          Manifest.new(manifest_path: @path, bytes: @historical.bytes)
        end

        # Return true while live bytes still prove the exact transition.
        # Changed manifest or destination raises ValidationError.
        def assert_current!
          check!(File.binread(@path) == @promoted_bytes,
                 "live catalog manifest differs from the exact approved promotion")
          check!(File.file?(@destination) && CatalogStorage.file_binding(@destination) == @candidate_binding,
                 "promoted catalog artifact changed during replay")
          true
        end

        private

        # Raise a compatible replay validation error if an observation differs.
        def check!(condition, message)
          raise ValidationError, message unless condition
        end
      end

      # Obtain and validate one manifest with its clean Git root/head/remote.
      # Returns the bound manifest and Git identities. Unusable state raises Error.
      def self.review!(manifest_path)
        state = Manifest.new(manifest_path:)
        state.validate!
        root = File.dirname(manifest_path)
        repository_root = File.expand_path(git!(root, "rev-parse", "--show-toplevel").strip)
        unless File.realpath(repository_root) == File.realpath(root)
          raise Error, "PROJECT_STATE.yml must be at the catalog repository root: #{root}"
        end
        head = git!(repository_root, "rev-parse", "HEAD").strip
        remote = git_origin(repository_root)
        name = File.basename(manifest_path)
        unless git!(repository_root, "status", "--porcelain=v1", "--", name).strip.empty?
          raise Error, "#{name} already has local changes; resolve them before adoption"
        end
        [state, repository_root, head, remote]
      end

      # Hold the physical catalog directory's advisory lock through the workflow.
      # Aliases and processes with different temporary directories share this
      # inode, which survives manifest replacement. Returns the block's result.
      def self.with_lock(root)
        File.open(File.realpath(root), File::RDONLY) do |directory|
          raise Error, "could not lock catalog repository: #{root}" unless directory.flock(File::LOCK_EX)
          yield new(directory)
        end
      end

      # Return a file's content hash and byte count. Read failures propagate.
      def self.file_binding(path)
        {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
      end

      # Observe Git without updating the index. Returns stdout or raises Error.
      def self.git!(root, *args)
        environment = args.first == "status" ? [{"GIT_OPTIONAL_LOCKS" => "0"}] : []
        stdout, stderr, status = Open3.capture3(*environment, "git", "-C", root, *args)
        return stdout if status.success?
        detail = stderr.strip.empty? ? stdout.strip : stderr.strip
        raise Error, "git #{args.first} failed#{detail.empty? ? '' : ": #{detail}"}"
      end

      # Return the exact origin locator or nil when the repository has no origin.
      # Other read failures raise Error.
      def self.git_origin(root)
        stdout, stderr, status = Open3.capture3("git", "-C", root, "remote", "get-url", "origin")
        return stdout.strip if status.success?
        return nil if stderr.include?("No such remote")
        raise Error, "git remote failed: #{stderr.strip}"
      end

      # Bind the open, locked directory to this transaction instance.
      def initialize(directory)
        @directory = directory
      end
      private_class_method :new

      # Validate the exact reviewed repository, source bytes and prior manifest.
      # Return the bound manifest. Changed identities raise Error.
      def assert_prior!(snapshot)
        assert_repository!(snapshot)
        assert_candidate!(snapshot)
        state = Manifest.new(manifest_path: snapshot.manifest_path)
        check!(state.binding == snapshot.prior_manifest,
               "project_state manifest bytes changed after review; prepare a fresh review")
        state.validate!
        check!(state.roles == snapshot.roles, "project-state roles changed after review; prepare a fresh review")
        state
      end

      # Return the exact live catalog role if already adopted, or nil if the
      # live head is different. Inexact replay observations raise Error.
      def replay(snapshot)
        state = Manifest.new(manifest_path: snapshot.manifest_path)
        state.validate!
        return unless state.roles.fetch("catalog_head") == snapshot.candidate
        check!(state.roles.except("catalog_head") == snapshot.roles.except("catalog_head"),
               "approval-relevant independent project_state roles changed after review")
        assert_repository!(snapshot)
        assert_candidate!(snapshot, "reviewed candidate no longer matches the promoted catalog artifact")
        assert_destination!(snapshot, expected: true, message: "promoted catalog artifact no longer matches the reviewed candidate")
        unless state.binding == snapshot.prior_manifest && state.roles == snapshot.roles
          Replay.new(snapshot:, historical_binding: {"path" => snapshot.manifest_path, **snapshot.prior_manifest})
        end
        state.resolve("catalog_head")
      end

      # Import only the reviewed workbook and atomically advance catalog_head.
      # The caller's block revalidates policy before replacement. Refusal cleans
      # up an import only when this transaction owns its inode and did not commit.
      # Returns the new role and whether the transaction imported the workbook.
      def publish!(snapshot)
        imported = replacement_inode = nil
        committed = false
        assert_prior!(snapshot)
        assert_destination!(snapshot, expected: snapshot.reuse_existing || in_place?(snapshot))
        unless snapshot.reuse_existing || in_place?(snapshot)
          Tempfile.create([".af-catalog-adoption-", ".xlsx"], File.dirname(snapshot.destination), binmode: true) do |temp|
            IO.copy_stream(snapshot.candidate_path, temp)
            temp.flush
            temp.fsync
            check!(self.class.file_binding(temp.path) == snapshot.candidate.slice("sha256", "bytes"),
                   "copied AMC bytes do not match the reviewed artifact")
            imported = temp.stat
            link_import!(temp.path, snapshot.destination)
          end
        end

        yield
        state = assert_prior!(snapshot)
        assert_destination!(snapshot, expected: true, imported:)
        replacement = state.promoted_bytes(snapshot.candidate)
        Tempfile.create([".af-catalog-adoption-", ".yml"], File.dirname(snapshot.manifest_path), binmode: true) do |temp|
          temp.chmod(File.stat(snapshot.manifest_path).mode & 0o777)
          temp.write(replacement)
          temp.flush
          temp.fsync
          assert_prior!(snapshot)
          assert_destination!(snapshot, expected: true, imported:)
          replacement_inode = temp.stat
          File.rename(temp.path, snapshot.manifest_path)
          committed = true
        end
        published = Manifest.new(manifest_path: snapshot.manifest_path)
        check!(published.bytes == replacement, "live catalog manifest differs from the approved promotion")
        [published.resolve("catalog_head"), !imported.nil?]
      ensure
        if imported && !committed && !same_inode?(snapshot.manifest_path, replacement_inode) &&
           same_inode?(snapshot.destination, imported) &&
           self.class.file_binding(snapshot.destination) == snapshot.candidate.slice("sha256", "bytes")
          File.unlink(snapshot.destination)
        end
      end

      private

      # Verify the locked root and reviewed repository identity before use.
      # A moved root, HEAD or remote raises Error.
      def assert_repository!(snapshot)
        root = File.realpath(snapshot.repository_root)
        check!(!File.symlink?(snapshot.manifest_path) &&
               File.dirname(File.realpath(snapshot.manifest_path)) == root && same_inode?(root, @directory.stat) &&
               File.realpath(self.class.git!(root, "rev-parse", "--show-toplevel").strip) == root,
               "catalog repository root changed after review; prepare a fresh review")
        check!(self.class.git!(root, "rev-parse", "HEAD").strip == snapshot.repository_head,
               "catalog repository HEAD changed after review; prepare a fresh review")
        check!(self.class.git_origin(root) == snapshot.repository_remote,
               "catalog repository remote changed after review; prepare a fresh review")
      end

      # Verify the source still contains exactly the reviewed workbook or raise Error.
      def assert_candidate!(snapshot, message = "AMC artifact changed after review; prepare a fresh review")
        path = snapshot.candidate_path
        check!(File.file?(path) && self.class.file_binding(path) == snapshot.candidate.slice("sha256", "bytes"), message)
      end

      # Verify the canonical destination and absence or exact expected bytes.
      # When this transaction imported the file, also require its inode.
      def assert_destination!(snapshot, expected:, imported: nil, message: nil)
        path = snapshot.destination
        expected_name = "5e_Adventure_Master_Catalog_#{snapshot.version}.xlsx"
        check!(ProjectState::VERSION_RE.match?(snapshot.version) && snapshot.candidate["version"] == snapshot.version &&
               snapshot.candidate["filename"] == expected_name &&
               path == File.join(File.dirname(snapshot.manifest_path), expected_name),
               "import destination differs from the reviewed catalog")
        if expected
          message ||= imported ? "imported destination differs from the reviewed candidate" :
            "existing import destination changed after review; prepare a fresh review"
          check!(File.file?(path) && self.class.file_binding(path) == snapshot.candidate.slice("sha256", "bytes") &&
                 (!imported || same_inode?(path, imported)), message)
        else
          check!(!File.exist?(path) && !File.symlink?(path),
                 "import destination was created after review; prepare a fresh review")
        end
      end

      # Return whether the reviewed candidate already is the destination.
      def in_place?(snapshot)
        snapshot.candidate_path == File.expand_path(snapshot.destination)
      end

      # Publish exclusively or raise a compatible conflict error.
      def link_import!(source, destination)
        File.link(source, destination)
      rescue Errno::EEXIST
        raise Error, "refusing to overwrite existing AMC artifact: #{destination}"
      end

      # Compare filesystem identity without following a replacement symlink.
      # An absent path or unset stat cannot identify an owned file.
      def same_inode?(path, stat)
        return false unless stat
        actual = File.lstat(path)
        actual.dev == stat.dev && actual.ino == stat.ino
      rescue Errno::ENOENT
        false
      end

      # Raise a compatible storage error when a reviewed invariant differs.
      def check!(condition, message)
        raise Error, message unless condition
      end
    end
  end
end
