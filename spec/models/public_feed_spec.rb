# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PublicFeed do
  let(:account) { Fabricate(:account) }

  describe '#get' do
    subject { described_class.new(nil).get(20).map(&:id) }

    it 'only includes statuses with public visibility' do
      public_status = Fabricate(:status, visibility: :public)
      private_status = Fabricate(:status, visibility: :private)

      expect(subject).to include(public_status.id)
      expect(subject).to_not include(private_status.id)
    end

    it 'does not include replies' do
      status = Fabricate(:status)
      reply = Fabricate(:status, in_reply_to_id: status.id)

      expect(subject).to include(status.id)
      expect(subject).to_not include(reply.id)
    end

    it 'does not include boosts' do
      status = Fabricate(:status)
      boost = Fabricate(:status, reblog_of_id: status.id)

      expect(subject).to include(status.id)
      expect(subject).to_not include(boost.id)
    end

    context 'with with_reblogs option' do
      subject { described_class.new(nil, with_reblogs: true).get(20).map(&:id) }

      let!(:poster)  { Fabricate(:account, domain: nil) }
      let!(:booster) { Fabricate(:account, domain: nil) }
      let!(:second_booster) { Fabricate(:account, domain: nil) }
      let!(:remote_booster) { Fabricate(:account, domain: 'example.com') }

      it 'does include boosts' do
        status = Fabricate(:status)
        boost = Fabricate(:status, reblog_of_id: status.id)

        expect(subject).to include(status.id)
        expect(subject).to include(boost.id)
      end

      it 'only includes the most recent boost' do
        status = Fabricate(:status, account: poster)
        boost = Fabricate(:status, reblog_of_id: status.id, account: poster)
        second_boost = Fabricate(:status, reblog_of_id: status.id, account: booster)
        third_boost = Fabricate(:status, reblog_of_id: status.id, account: second_booster)

        expect(subject).to include(status.id)
        expect(subject).to_not include(boost.id)
        expect(subject).to_not include(second_boost.id)
        expect(subject).to include(third_boost.id)
      end

      it 'filters duplicate boosts across pagination' do
        status = Fabricate(:status, account: poster)

        boost = Fabricate(:status, reblog_of_id: status.id, id: status.id + 1, account: poster)

        # sleep for 2ms to make sure the other posts come in a greater snowflake ID
        sleep(0.002)

        n_posts = 20
        (1..n_posts).each do |i|
          Fabricate(:status, account: poster, id: boost.id + i)
        end

        # before a second boost, the second page should still include the original boost
        second_page = described_class.new(nil, with_reblogs: true).get(20, boost.id + 1).map(&:id)
        expect(second_page).to include(boost.id)

        # after a second boost, the second page should no longer include the original boost
        second_boost = Fabricate(:status, reblog_of_id: status.id, id: boost.id + n_posts + 1, account: booster)
        second_page = described_class.new(nil, with_reblogs: true).get(20, boost.id + 1).map(&:id)

        expect(subject).to include(second_boost.id)
        expect(second_page).to_not include(boost.id)
      end

      context 'with local option' do
        subject { described_class.new(nil, with_reblogs: true, local: true, remote: false).get(20).map(&:id) }

        it 'shows the most recent local boost when there is a more recent remote boost' do
          status = Fabricate(:status, account: poster)
          local_boost = Fabricate(:status, reblog_of_id: status.id, local: true, account: booster)
          remote_boost = Fabricate(:status, reblog_of_id: status.id, id: local_boost.id + 1, local: false, uri: 'https://example.com/boosturl', account: remote_booster)

          expect(subject).to include(local_boost.id)
          expect(subject).to_not include(remote_boost.id)
        end
      end

      context 'with remote option' do
        subject { described_class.new(nil, with_reblogs: true, local: false, remote: true).get(20).map(&:id) }

        it 'shows the most recent remote boost when there is a more recent local boost' do
          status = Fabricate(:status, account: poster)
          remote_boost = Fabricate(:status, reblog_of_id: status.id, local: false, uri: 'https://example.com/boosturl', account: remote_booster)
          local_boost = Fabricate(:status, reblog_of_id: status.id, id: remote_boost.id + 1, local: true, account: booster)

          expect(subject).to include(remote_boost.id)
          expect(subject).to_not include(local_boost.id)
        end
      end
    end

    it 'filters out silenced accounts' do
      silenced_account = Fabricate(:account, silenced: true)
      status = Fabricate(:status, account: account)
      silenced_status = Fabricate(:status, account: silenced_account)

      expect(subject).to include(status.id)
      expect(subject).to_not include(silenced_status.id)
    end

    context 'without local_only option' do
      subject { described_class.new(viewer).get(20).map(&:id) }

      let(:viewer) { nil }

      let!(:local_account)  { Fabricate(:account, domain: nil) }
      let!(:remote_account) { Fabricate(:account, domain: 'test.com') }
      let!(:local_status)   { Fabricate(:status, account: local_account) }
      let!(:remote_status)  { Fabricate(:status, account: remote_account) }
      let!(:local_only_status) { Fabricate(:status, account: local_account, local_only: true) }

      context 'without a viewer' do
        let(:viewer) { nil }

        it 'includes remote instances statuses and local statuses' do
          expect(subject)
            .to include(remote_status.id)
            .and include(local_status.id)
        end

        it 'does not include local-only statuses' do
          expect(subject).to_not include(local_only_status.id)
        end
      end

      context 'with a viewer' do
        let(:viewer) { Fabricate(:account, username: 'viewer') }

        it 'includes remote instances statuses and local statuses' do
          expect(subject)
            .to include(remote_status.id)
            .and include(local_status.id)
        end

        it 'does not include local-only statuses' do
          expect(subject).to_not include(local_only_status.id)
        end
      end
    end

    context 'without local_only option but allow_local_only' do
      subject { described_class.new(viewer, allow_local_only: true).get(20).map(&:id) }

      let(:viewer) { nil }

      let!(:local_account)  { Fabricate(:account, domain: nil) }
      let!(:remote_account) { Fabricate(:account, domain: 'test.com') }
      let!(:local_status)   { Fabricate(:status, account: local_account) }
      let!(:remote_status)  { Fabricate(:status, account: remote_account) }
      let!(:local_only_status) { Fabricate(:status, account: local_account, local_only: true) }

      context 'without a viewer' do
        let(:viewer) { nil }

        it 'includes remote instances statuses' do
          expect(subject).to include(remote_status.id)
        end

        it 'includes local statuses' do
          expect(subject).to include(local_status.id)
        end

        it 'does not include local-only statuses' do
          expect(subject).to_not include(local_only_status.id)
        end
      end

      context 'with a viewer' do
        let(:viewer) { Fabricate(:account, username: 'viewer') }

        it 'includes remote instances statuses' do
          expect(subject).to include(remote_status.id)
        end

        it 'includes local statuses' do
          expect(subject).to include(local_status.id)
        end

        it 'includes local-only statuses' do
          expect(subject).to include(local_only_status.id)
        end
      end
    end

    context 'with a local_only option set' do
      subject { described_class.new(viewer, local: true).get(20).map(&:id) }

      let!(:local_account)  { Fabricate(:account, domain: nil) }
      let!(:remote_account) { Fabricate(:account, domain: 'test.com') }
      let!(:local_status)   { Fabricate(:status, account: local_account) }
      let!(:remote_status)  { Fabricate(:status, account: remote_account) }
      let!(:local_only_status) { Fabricate(:status, account: local_account, local_only: true) }

      context 'without a viewer' do
        let(:viewer) { nil }

        it 'does not include remote instances statuses' do
          expect(subject).to include(local_status.id)
          expect(subject).to_not include(remote_status.id)
        end

        it 'does not include local-only statuses' do
          expect(subject).to_not include(local_only_status.id)
        end
      end

      context 'with a viewer' do
        let(:viewer) { Fabricate(:account, username: 'viewer') }

        it 'does not include remote instances statuses' do
          expect(subject).to include(local_status.id)
          expect(subject).to_not include(remote_status.id)
        end

        it 'is not affected by personal domain blocks' do
          viewer.block_domain!('test.com')
          expect(subject).to include(local_status.id)
          expect(subject).to_not include(remote_status.id)
        end

        it 'includes local-only statuses' do
          expect(subject).to include(local_only_status.id)
        end
      end
    end

    context 'with a remote_only option set' do
      subject { described_class.new(viewer, remote: true).get(20).map(&:id) }

      let!(:local_account)  { Fabricate(:account, domain: nil) }
      let!(:remote_account) { Fabricate(:account, domain: 'test.com') }
      let!(:local_status)   { Fabricate(:status, account: local_account) }
      let!(:remote_status)  { Fabricate(:status, account: remote_account) }

      context 'without a viewer' do
        let(:viewer) { nil }

        it 'does not include local instances statuses' do
          expect(subject).to_not include(local_status.id)
          expect(subject).to include(remote_status.id)
        end
      end

      context 'with a viewer' do
        let(:viewer) { Fabricate(:account, username: 'viewer') }

        it 'does not include local instances statuses' do
          expect(subject).to_not include(local_status.id)
          expect(subject).to include(remote_status.id)
        end
      end
    end

    describe 'with an account passed in' do
      subject { described_class.new(account).get(20).map(&:id) }

      let!(:account) { Fabricate(:account) }

      it 'excludes statuses from accounts blocked by the account' do
        blocked = Fabricate(:account)
        account.block!(blocked)
        blocked_status = Fabricate(:status, account: blocked)

        expect(subject).to_not include(blocked_status.id)
      end

      it 'excludes statuses from accounts who have blocked the account' do
        blocker = Fabricate(:account)
        blocker.block!(account)
        blocked_status = Fabricate(:status, account: blocker)

        expect(subject).to_not include(blocked_status.id)
      end

      it 'excludes statuses from accounts muted by the account' do
        muted = Fabricate(:account)
        account.mute!(muted)
        muted_status = Fabricate(:status, account: muted)

        expect(subject).to_not include(muted_status.id)
      end

      it 'excludes statuses from accounts from personally blocked domains' do
        blocked = Fabricate(:account, domain: 'example.com')
        account.block_domain!(blocked.domain)
        blocked_status = Fabricate(:status, account: blocked)

        expect(subject).to_not include(blocked_status.id)
      end

      context 'with language preferences' do
        it 'excludes statuses in languages not allowed by the account user' do
          account.user.update(chosen_languages: [:en, :es])
          en_status = Fabricate(:status, language: 'en')
          es_status = Fabricate(:status, language: 'es')
          fr_status = Fabricate(:status, language: 'fr')

          expect(subject).to include(en_status.id)
          expect(subject).to include(es_status.id)
          expect(subject).to_not include(fr_status.id)
        end

        it 'includes all languages when user does not have a setting' do
          account.user.update(chosen_languages: nil)

          en_status = Fabricate(:status, language: 'en')
          es_status = Fabricate(:status, language: 'es')

          expect(subject).to include(en_status.id)
          expect(subject).to include(es_status.id)
        end

        it 'includes all languages when account does not have a user' do
          account.update(user: nil)

          en_status = Fabricate(:status, language: 'en')
          es_status = Fabricate(:status, language: 'es')

          expect(subject).to include(en_status.id)
          expect(subject).to include(es_status.id)
        end
      end
    end
  end
end
