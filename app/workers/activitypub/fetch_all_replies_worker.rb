# frozen_string_literal: true

# Fetch all replies to a status, querying recursively through
# ActivityPub replies collections, fetching any statuses that
# we either don't already have or we haven't checked for new replies
# in the Status::FETCH_REPLIES_DEBOUNCE interval
class ActivityPub::FetchAllRepliesWorker
  include Sidekiq::Worker
  include ExponentialBackoff
  include JsonLdHelper

  sidekiq_options queue: 'pull', retry: 3

  # Global max replies to fetch per request (all replies, recursively)
  MAX_REPLIES = (ENV['FETCH_REPLIES_MAX_GLOBAL'] || 1000).to_i

  def perform(parent_status_id, options = {})
    @parent_status = Status.find(parent_status_id)
    Rails.logger.debug { "FetchAllRepliesWorker - #{@parent_status.uri}: Fetching all replies for status: #{@parent_status}" }

    # Refetch parent status and replies with one request
    @parent_status_json = fetch_resource(@parent_status.uri, true)
    raise UnexpectedResponseError("Could not fetch ActivityPub JSON for parent status: #{@parent_status.uri}") if @parent_status_json.nil?

    FetchReplyWorker.perform_async(@parent_status.uri, { 'prefetched_body' => @parent_status_json })
    uris_to_fetch = get_replies(@parent_status.uri, @parent_status_json, options)
    return if uris_to_fetch.nil?

    @parent_status.touch(:fetched_replies_at)

    fetched_uris = uris_to_fetch.clone.to_set

    until uris_to_fetch.empty? || fetched_uris.length >= MAX_REPLIES
      next_reply = uris_to_fetch.pop
      next if next_reply.nil?

      new_reply_uris = get_replies(next_reply, nil, options)
      next if new_reply_uris.nil?

      new_reply_uris = new_reply_uris.reject { |uri| fetched_uris.include?(uri) }

      uris_to_fetch.concat(new_reply_uris)
      fetched_uris = fetched_uris.merge(new_reply_uris)
    end

    Rails.logger.debug { "FetchAllRepliesWorker - #{parent_status_id}: fetched #{fetched_uris.length} replies" }
    fetched_uris
  end

  private

  def get_replies(status_uri, prefetched_body = nil, options = {})
    replies_collection_or_uri = get_replies_uri(status_uri, prefetched_body)
    return if replies_collection_or_uri.nil?

    ActivityPub::FetchAllRepliesService.new.call(replies_collection_or_uri, **options.deep_symbolize_keys)
  end

  def get_replies_uri(parent_status_uri, prefetched_body = nil)
    begin
      json_status = prefetched_body.nil? ? fetch_resource(parent_status_uri, true) : prefetched_body

      if json_status.nil?
        Rails.logger.debug { "FetchAllRepliesWorker - #{@parent_status.uri}: error getting replies URI for #{parent_status_uri}, returned nil" }
        nil
      elsif !json_status.key?('replies')
        Rails.logger.debug { "FetchAllRepliesWorker - #{@parent_status.uri}: no replies collection found in ActivityPub object: #{json_status}" }
        nil
      else
        json_status['replies']
      end
    rescue => e
      Rails.logger.warn { "FetchAllRepliesWorker - #{@parent_status.uri}: caught exception fetching replies URI: #{e}" }
      # Raise if we can't get the collection for top-level status to trigger retry
      raise e if parent_status_uri == @parent_status.uri

      nil
    end
  end
end
