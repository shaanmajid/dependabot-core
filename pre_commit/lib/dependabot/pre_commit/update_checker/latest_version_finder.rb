# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "dependabot/clients/github_with_retries"
require "dependabot/errors"
require "dependabot/pre_commit/comment_version_helper"
require "dependabot/pre_commit/file_parser"
require "dependabot/pre_commit/package/package_details_fetcher"
require "dependabot/pre_commit/requirement"
require "dependabot/pre_commit/update_checker"
require "dependabot/pre_commit/helpers"
require "dependabot/package/package_latest_version_finder"
require "dependabot/shared_helpers"
require "dependabot/update_checkers/cooldown_calculation"
require "dependabot/update_checkers/version_filters"

module Dependabot
  module PreCommit
    class UpdateChecker
      class LatestVersionFinder < Dependabot::Package::PackageLatestVersionFinder
        extend T::Sig

        sig do
          params(
            dependency: Dependabot::Dependency,
            dependency_files: T::Array[Dependabot::DependencyFile],
            credentials: T::Array[Dependabot::Credential],
            ignored_versions: T::Array[String],
            raise_on_ignored: T::Boolean,
            options: T::Hash[Symbol, T.untyped],
            cooldown_options: T.nilable(Dependabot::Package::ReleaseCooldownOptions)
          ).void
        end
        def initialize(
          dependency:,
          dependency_files:,
          credentials:,
          ignored_versions:,
          raise_on_ignored:,
          options: {},
          cooldown_options: nil
        )
          @dependency          = dependency
          @dependency_files    = dependency_files
          @credentials         = credentials
          @ignored_versions    = ignored_versions
          @raise_on_ignored    = raise_on_ignored
          @options             = options
          @cooldown_options = cooldown_options
          @cooldown_selected_tag = T.let(nil, T.nilable(T::Hash[Symbol, T.untyped]))
          @cooldown_rejected_all = T.let(false, T::Boolean)
          @cooldown_checked = T.let(false, T::Boolean)

          @git_helper = T.let(git_helper, Dependabot::PreCommit::Helpers::Githelper)
          super(
            dependency: dependency,
            dependency_files: dependency_files,
            credentials: credentials,
            ignored_versions: ignored_versions,
            security_advisories: [],
            cooldown_options: cooldown_options,
            raise_on_ignored: raise_on_ignored,
            options: options
          )
        end

        sig { returns(Dependabot::Dependency) }
        attr_reader :dependency

        sig { returns(T::Array[Dependabot::Credential]) }
        attr_reader :credentials

        sig { returns(T.nilable(Dependabot::Package::ReleaseCooldownOptions)) }
        attr_reader :cooldown_options

        sig { returns(T::Array[String]) }
        attr_reader :ignored_versions

        sig { returns(T::Boolean) }
        attr_reader :raise_on_ignored

        sig { override.returns(T.nilable(Dependabot::Package::PackageDetails)) }
        def package_details; end

        sig { returns(T.nilable(T.any(Dependabot::Version, String))) }
        def latest_release_version
          release = available_release
          return nil unless release

          Dependabot.logger.info("Available release version/ref is #{release}")

          filter_release_with_cooldown(release)
        end

        sig { returns(T.nilable(T::Hash[Symbol, T.untyped])) }
        def latest_version_tag
          return nil if @cooldown_rejected_all

          latest_release_version if cooldown_options && !release_type_sha? && !@cooldown_checked

          return nil if @cooldown_rejected_all
          return @cooldown_selected_tag if @cooldown_selected_tag
          return nil if @cooldown_checked

          available_latest_version_tag
        end

        private

        sig do
          params(release: T.any(Dependabot::Version, String))
            .returns(T.nilable(T.any(Dependabot::Version, String)))
        end
        def filter_release_with_cooldown(release)
          return release unless cooldown_enabled?
          return release unless cooldown_options
          # Commit SHA releases have no version ordering to fall back through
          return release if release_type_sha?

          Dependabot.logger.info("Applying cooldown filter for #{dependency.name}")
          @cooldown_checked = true

          result = find_latest_version_outside_cooldown
          return result if result

          Dependabot.logger.info("All candidate versions are in cooldown, keeping current version #{current_version}")
          @cooldown_rejected_all = true
          current_version
        end

        sig { returns(T.nilable(Dependabot::PreCommit::Package::PackageDetailsFetcher)) }
        def package_details_fetcher
          @package_details_fetcher ||= T.let(
            Dependabot::PreCommit::Package::PackageDetailsFetcher
                        .new(
                          dependency: dependency,
                          credentials: credentials,
                          ignored_versions: ignored_versions,
                          raise_on_ignored: raise_on_ignored
                        ),
            T.nilable(Dependabot::PreCommit::Package::PackageDetailsFetcher)
          )
        end

        sig { returns(T.nilable(T.any(Dependabot::Version, String))) }
        def available_release
          @available_release = T.let(
            T.must(package_details_fetcher).release_list_for_git_dependency,
            T.nilable(T.any(Dependabot::Version, String))
          )
        end

        sig { returns(T.nilable(T::Hash[Symbol, T.untyped])) }
        def available_latest_version_tag
          @latest_version_tag = T.let(
            T.must(package_details_fetcher).latest_version_tag,
            T.nilable(T::Hash[Symbol, T.untyped])
          )
        end

        sig { override.returns(T::Boolean) }
        def cooldown_enabled?
          true
        end

        # Checks versions from latest downward (among versions > current_version)
        # in a single bare clone. Returns the newest version outside cooldown,
        # or nil if all candidates are within cooldown.
        sig { returns(T.nilable(Dependabot::Version)) }
        def find_latest_version_outside_cooldown
          candidates = version_candidates_descending
          return nil if candidates.empty?

          url = @git_helper.git_commit_checker.dependency_source_details&.fetch(:url)
          source = T.must(Source.from_url(url))

          SharedHelpers.in_a_temporary_directory(File.dirname(source.repo)) do |temp_dir|
            repo_contents_path = File.join(temp_dir, File.basename(source.repo))
            SharedHelpers.run_shell_command("git clone --bare --no-recurse-submodules #{url} #{repo_contents_path}")

            Dir.chdir(repo_contents_path) do
              github_client_for_cooldown(source)
              return check_candidates_cooldown(candidates, source)
            end
          end
        rescue StandardError => e
          Dependabot.logger.error("Error checking cooldown for #{dependency.name}: #{e.message}")
          nil
        end

        # Iterates candidate tags inside a bare clone directory, returning the first
        # version whose release date falls outside the cooldown window.
        sig do
          params(
            candidates: T::Array[T::Hash[Symbol, T.untyped]],
            source: Dependabot::Source
          )
            .returns(T.nilable(Dependabot::Version))
        end
        def check_candidates_cooldown(candidates, source)
          filtered_count = 0

          candidates.each do |tag|
            release_date = release_date_for_tag(tag, source)
            unless release_date
              filtered_count += 1
              next
            end

            if release_in_cooldown_period?(release_date)
              filtered_count += 1
            else
              log_cooldown_result(filtered_count, tag[:version], release_date)
              @cooldown_selected_tag = tag
              return T.cast(tag[:version], Dependabot::Version)
            end
          end

          Dependabot.logger.info(
            "Filtered #{filtered_count} version(s) due to cooldown for #{dependency.name}, " \
            "no eligible version found"
          )
          nil
        end

        sig do
          params(
            tag: T::Hash[Symbol, T.untyped],
            source: Dependabot::Source
          ).returns(T.nilable(Time))
        end
        def release_date_for_tag(tag, source)
          github_release_date = github_release_date_for_tag(tag, source)
          git_date = begin
            git_date_for_tag(tag)
          rescue StandardError => e
            raise unless github_release_date

            Dependabot.logger.warn(
              "Error checking git release date for #{dependency.name} tag #{tag[:tag]}: #{e.message}"
            )
            nil
          end

          [github_release_date, git_date].compact.max
        rescue StandardError => e
          Dependabot.logger.warn(
            "Error checking release date for #{dependency.name} tag #{tag[:tag]}: #{e.message}"
          )
          nil
        end

        sig { params(tag: T::Hash[Symbol, T.untyped]).returns(T.nilable(Time)) }
        def git_date_for_tag(tag)
          tag_name = T.cast(tag[:tag], T.nilable(String))
          if tag_name
            begin
              date_str = SharedHelpers.run_shell_command(
                "git for-each-ref --format=\"%(creatordate:iso-strict)\" " \
                "refs/tags/#{normalized_tag_name(tag_name)}",
                fingerprint: "git for-each-ref --format=\"%(creatordate:iso-strict)\" refs/tags/<tag>"
              )
              return Time.parse(date_str) if date_str.strip.length.positive?
            rescue StandardError => e
              Dependabot.logger.warn(
                "Error checking git tag date for #{dependency.name} tag #{tag[:tag]}: #{e.message}"
              )
            end
          end

          commit_sha = T.cast(tag[:commit_sha], T.nilable(String))
          return unless commit_sha

          date_str = SharedHelpers.run_shell_command(
            "git show --no-patch --format=\"%cd\" --date=iso #{commit_sha}",
            fingerprint: "git show --no-patch --format=\"%cd\" --date=iso <commit_sha>"
          )
          Time.parse(date_str)
        end

        sig do
          params(
            tag: T::Hash[Symbol, T.untyped],
            source: Dependabot::Source
          ).returns(T.nilable(Time))
        end
        def github_release_date_for_tag(tag, source)
          client = github_client_for_cooldown(source)
          return unless client

          # rubocop:disable Style/SendWithLiteralMethodName
          release = client.public_send(
            :release_for_tag,
            source.repo,
            normalized_tag_name(T.cast(tag[:tag], String))
          )
          published_at = release.public_send(:published_at)
          # rubocop:enable Style/SendWithLiteralMethodName
          return unless published_at

          published_at.is_a?(Time) ? published_at : Time.parse(published_at.to_s)
        rescue Octokit::NotFound
          nil
        end

        sig { params(source: Dependabot::Source).returns(T.nilable(Dependabot::Clients::GithubWithRetries)) }
        def github_client_for_cooldown(source)
          return unless source.provider == "github"

          @github_client_for_cooldown ||= T.let(
            Dependabot::Clients::GithubWithRetries.for_source(
              source: source,
              credentials: credentials
            ),
            T.nilable(Dependabot::Clients::GithubWithRetries)
          )
        end

        sig { params(tag_name: String).returns(String) }
        def normalized_tag_name(tag_name)
          tag_name.delete_prefix("refs/tags/").delete_prefix("tags/")
        end

        sig do
          params(filtered_count: Integer, version: T.untyped, release_date: Time).void
        end
        def log_cooldown_result(filtered_count, version, release_date)
          if filtered_count.positive?
            Dependabot.logger.info(
              "Filtered #{filtered_count} version(s) due to cooldown for #{dependency.name}"
            )
          end
          Dependabot.logger.info("Selected version #{version} (released #{release_date})")
        end

        # Returns all version tags > current_version, sorted descending (latest first).
        # This ensures we evaluate from the newest candidate downward.
        sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
        def version_candidates_descending
          cur_version = current_version
          all_tags = cooldown_candidate_tags(cur_version)

          all_tags
            .select { |tag| tag[:version].is_a?(Gem::Version) }
            .select { |tag| cur_version.nil? || tag[:version] > cur_version }
            .sort_by { |tag| tag[:version] }
            .reverse
        end

        sig do
          params(cur_version: T.nilable(T.any(Dependabot::Version, String)))
            .returns(T::Array[T::Hash[Symbol, T.untyped]])
        end
        def cooldown_candidate_tags(cur_version)
          checker = @git_helper.git_commit_checker
          if cur_version.is_a?(Gem::Version) && checker.pinned_ref_looks_like_commit_sha?
            return checker.local_tags_for_allowed_versions
          end

          checker.local_tags_for_allowed_versions_matching_existing_precision
        end

        sig { params(release_date: Time).returns(T::Boolean) }
        def release_in_cooldown_period?(release_date)
          cooldown = @cooldown_options

          return false unless T.must(cooldown).included?(dependency.name)

          days = T.must(cooldown).default_days

          Dependabot::UpdateCheckers::CooldownCalculation
            .within_cooldown_window?(release_date, days)
        end

        sig { returns(T.nilable(T.any(Dependabot::Version, String))) }
        def current_version
          return dependency.source_details(allowed_types: ["git"])&.fetch(:ref) if release_type_sha?

          # numeric_version handles plain versions like "4.4.0"
          numeric = dependency.numeric_version
          return numeric if numeric

          version_for_pinned_sha = version_from_git_ref(@git_helper.git_commit_checker.local_tag_for_pinned_sha)
          return version_for_pinned_sha if version_for_pinned_sha

          comment_version = version_from_comment
          return comment_version if comment_version

          # Handle v-prefixed tags like "v4.4.0" common in pre-commit
          version_from_git_ref(dependency.version)
        end

        sig { params(ref: T.nilable(String)).returns(T.nilable(Dependabot::Version)) }
        def version_from_git_ref(ref)
          return unless ref

          version = ref.match(/(?:\A|[^0-9A-Za-z])(?<version>v?\d+(?:\.[A-Za-z0-9-]+)*)\z/i)&.[](:version) ||
                    ref.match(/\A(?<version>v?\d+(?:\.[A-Za-z0-9-]+)*)\z/i)&.[](:version)
          return unless version

          stripped = version.sub(/\Av/i, "")
          return nil unless Dependabot::PreCommit::Version.correct?(stripped)

          Dependabot::PreCommit::Version.new(stripped)
        end

        sig { returns(T.nilable(Dependabot::Version)) }
        def version_from_comment
          comment = T.let(
            dependency.requirements
              .filter_map do |req|
                T.cast(req.fetch(:metadata, {}), T::Hash[Symbol, T.untyped])[:comment]
              end
              .first,
            T.nilable(String)
          )
          return unless comment

          version_from_git_ref(comment.match(CommentVersionHelper::COMMENT_VERSION_PATTERN)&.[](0))
        end

        sig { returns(T::Boolean) }
        def release_type_sha?
          available_release.is_a?(String)
        end

        sig { returns(Dependabot::PreCommit::Helpers::Githelper) }
        def git_helper
          Helpers::Githelper.new(
            dependency: dependency,
            credentials: credentials,
            ignored_versions: ignored_versions,
            raise_on_ignored: raise_on_ignored,
            consider_version_branches_pinned: false,
            dependency_source_details: nil
          )
        end
      end
    end
  end
end
