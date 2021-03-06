class CommitMonitorHandlers::CommitRange::RubocopChecker
  include Sidekiq::Worker
  sidekiq_options :queue => :miq_bot_glacial

  include BranchWorkerMixin

  def self.handled_branch_modes
    [:pr]
  end

  attr_reader :results, :github

  def perform(branch_id, _new_commits)
    return unless find_branch(branch_id, :pr)

    process_branch
  end

  private

  def process_branch
    unmerged_results = []
    unmerged_results << Linter::Rubocop.new(branch).run

    diff_details = diff_details_for_merge
    files = extract_haml_files(diff_details)
    if files.any?
      unmerged_results << linter_results('haml-lint', :reporter => 'json', nil => files)
    end

    unmerged_results.compact!
    if unmerged_results.empty?
      @results = {"files" => []}
    else
      results = merge_linter_results(*unmerged_results)
      @results = RubocopResultsFilter.new(results, diff_details).filtered
    end

    write_to_github
  end

  def extract_haml_files(diff_details)
    diff_details.keys.select do |k|
      k.end_with?(".haml")
    end
  end

  def linter_results(cmd, options = {})
    require 'awesome_spawn'

    result = branch.repo.with_git_service do |git|
      git.temporarily_checkout(commits.last) do
        logger.info("Executing: #{AwesomeSpawn.build_command_line(cmd, options)}")
        AwesomeSpawn.run(cmd, :params => options, :chdir => branch.repo.path)
      end
    end
    raise result.error if result.exit_status == 1 && result.error.present?

    JSON.parse(result.output.chomp)
  end

  def merge_linter_results(*results)
    return if results.empty?

    new_results = results[0].dup

    results[1..-1].each do |result|
      %w(offense_count target_file_count inspected_file_count).each do |m|
        new_results['summary'][m] += result['summary'][m]
      end
      new_results['files'] += result['files']
    end

    new_results
  end

  def rubocop_comments
    MessageBuilder.new(results, branch).comments
  end

  def write_to_github
    logger.info("Updating PR #{pr_number} with rubocop comment.")

    branch.repo.with_github_service do |github|
      @github = github
      replace_rubocop_comments
    end
  end

  def replace_rubocop_comments
    github.replace_issue_comments(pr_number, rubocop_comments) do |old_comment|
      rubocop_comment?(old_comment)
    end
  end

  def rubocop_comment?(comment)
    comment.body.start_with?("<rubocop />")
  end
end
