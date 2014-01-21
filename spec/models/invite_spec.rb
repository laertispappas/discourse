require 'spec_helper'

describe Invite do

  it { should belong_to :user }
  it { should have_many :topic_invites }
  it { should belong_to :invited_by }
  it { should have_many :topics }
  it { should validate_presence_of :email }
  it { should validate_presence_of :invited_by_id }

  let(:iceking) { 'iceking@adventuretime.ooo' }

  context 'user validators' do
    let(:coding_horror) { Fabricate(:coding_horror) }
    let(:user) { Fabricate(:user) }
    let(:invite) { Invite.create(email: user.email, invited_by: coding_horror) }

    it "should not allow an invite with the same email as an existing user" do
      invite.should_not be_valid
    end

    it "should not allow a user to invite themselves" do
      invite.email_already_exists.should be_true
    end

  end

  context '#create' do

    context 'saved' do
      subject { Fabricate(:invite) }
      its(:invite_key) { should be_present }
      its(:email_already_exists) { should be_false }

      it 'should store a lower case version of the email' do
        subject.email.should == iceking
      end
    end

    context 'to a topic' do
      let!(:topic) { Fabricate(:topic) }
      let(:inviter) { topic.user }

      context 'email' do
        it 'enqueues a job to email the invite' do
          Jobs.expects(:enqueue).with(:invite_email, has_key(:invite_id))
          topic.invite_by_email(inviter, iceking)
        end
      end

      context 'destroyed' do
        it "can invite the same user after their invite was destroyed" do
          invite = topic.invite_by_email(inviter, iceking)
          invite.destroy
          invite = topic.invite_by_email(inviter, iceking)
          invite.should be_present
        end
      end

      context 'after created' do
        before do
          @invite = topic.invite_by_email(inviter, iceking)
        end

        it 'belongs to the topic' do
          topic.invites.should == [@invite]
        end

        it 'has a topic' do
          @invite.topics.should == [topic]
        end

        context 'when added by another user' do
          let(:coding_horror) { Fabricate(:coding_horror) }
          let(:new_invite) { topic.invite_by_email(coding_horror, iceking) }

          it 'returns a different invite' do
            new_invite.should_not == @invite
          end

          it 'has a different key' do
            new_invite.invite_key.should_not == @invite.invite_key
          end

          it 'has the topic relationship' do
            new_invite.topics.should == [topic]
          end
        end

        context 'when adding a duplicate' do
          it 'returns the original invite' do
            topic.invite_by_email(inviter, 'iceking@adventuretime.ooo').should == @invite
          end

          it 'matches case insensitively for the domain part' do
            topic.invite_by_email(inviter, 'iceking@ADVENTURETIME.ooo').should == @invite
          end

          it 'matches case sensitively for the local part' do
            topic.invite_by_email(inviter, 'ICEKING@adventuretime.ooo').should_not == @invite
          end

          it 'returns a new invite if the other has expired' do
            SiteSetting.stubs(:invite_expiry_days).returns(1)
            @invite.created_at = 2.days.ago
            @invite.save
            new_invite = topic.invite_by_email(inviter, 'iceking@adventuretime.ooo')
            new_invite.should_not == @invite
            new_invite.should_not be_expired
          end
        end

        context 'when adding to another topic' do
          let!(:another_topic) { Fabricate(:topic, user: topic.user) }

          before do
            @new_invite = another_topic.invite_by_email(inviter, iceking)
          end

          it 'should be the same invite' do
            @new_invite.should == @invite
          end

          it 'belongs to the new topic' do
            another_topic.invites.should == [@invite]
          end

          it 'has references to both topics' do
            @invite.topics.should =~ [topic, another_topic]
          end
        end
      end
    end
  end

  context 'an existing user' do
    let(:topic) { Fabricate(:topic, archetype: Archetype.private_message) }
    let(:coding_horror) { Fabricate(:coding_horror) }
    let!(:invite) { topic.invite_by_email(topic.user, coding_horror.email) }

    it "doesn't create an invite" do
      invite.should be_blank
    end

    it "gives the user permission to access the topic" do
      topic.allowed_users.include?(coding_horror).should be_true
    end
  end

  context '.redeem' do

    let(:invite) { Fabricate(:invite) }

    it 'creates a notification for the invitee' do
      lambda { invite.redeem }.should change(Notification, :count)
    end

    it 'wont redeem an expired invite' do
      SiteSetting.expects(:invite_expiry_days).returns(10)
      invite.update_column(:created_at, 20.days.ago)
      invite.redeem.should be_blank
    end

    it 'wont redeem a deleted invite' do
      invite.destroy
      invite.redeem.should be_blank
    end

    context 'invite trust levels' do

      it "returns the trust level in default_invitee_trust_level" do
        SiteSetting.stubs(:default_invitee_trust_level).returns(TrustLevel.levels[:leader])
        invite.redeem.trust_level.should == TrustLevel.levels[:leader]
      end

      context "invited by a trust level 3 user" do
        let(:leader) { Fabricate(:user, trust_level: TrustLevel.levels[:leader]) }
        let(:invitation) { Fabricate(:invite, invited_by: leader) }

        it "default_invitee_trust_level is 1, then invited user should be trust level 2" do
          SiteSetting.stubs(:default_invitee_trust_level).returns(TrustLevel.levels[:basic])
          invitation.redeem.trust_level.should == TrustLevel.levels[:regular]
        end

        it "default_invitee_trust_level is 2, then invited user should be trust level 2" do
          SiteSetting.stubs(:default_invitee_trust_level).returns(TrustLevel.levels[:regular])
          invitation.redeem.trust_level.should == TrustLevel.levels[:regular]
        end

        it "default_invitee_trust_level is 3, then invited user should be trust level 3" do
          SiteSetting.stubs(:default_invitee_trust_level).returns(TrustLevel.levels[:leader])
          invitation.redeem.trust_level.should == TrustLevel.levels[:leader]
        end
      end
    end

    context 'inviting when must_approve_users? is enabled' do
      it 'correctly activates accounts' do
        SiteSetting.stubs(:must_approve_users).returns(true)
        user = invite.redeem

        user.approved?.should == true
      end
    end

    context 'simple invite' do

      let!(:user) { invite.redeem }

      it 'works correctly' do
        user.is_a?(User).should be_true
        user.send_welcome_message.should be_true
        user.trust_level.should == SiteSetting.default_invitee_trust_level
      end

      context 'after redeeming' do
        before do
          invite.reload
        end

        it 'works correctly' do
          # has set the user_id attribute
          invite.user.should == user

          # returns true for redeemed
          invite.should be_redeemed
        end


        context 'again' do
          it 'will not redeem twice' do
            invite.redeem.should == user
            invite.redeem.send_welcome_message.should be_false
          end

        end
      end

    end

    context 'invited to topics' do
      let!(:topic) { Fabricate(:private_message_topic) }
      let!(:invite) { topic.invite(topic.user, 'jake@adventuretime.ooo')}

      context 'redeem topic invite' do
        let!(:user) { invite.redeem }

        it 'adds the user to the topic_users' do
          topic.allowed_users.include?(user).should be_true
        end

        it 'can see the private topic' do
          Guardian.new(user).can_see?(topic).should be_true
        end
      end

      context 'invited by another user to the same topic' do
        let(:coding_horror) { User.where(username: 'CodingHorror').first }
        let!(:another_invite) { topic.invite(coding_horror, 'jake@adventuretime.ooo') }
        let!(:user) { invite.redeem }

        it 'adds the user to the topic_users' do
          topic.allowed_users.include?(user).should be_true
        end
      end

      context 'invited by another user to a different topic' do
        let(:coding_horror) { User.where(username: 'CodingHorror').first }
        let(:another_topic) { Fabricate(:topic, archetype: "private_message", user: coding_horror) }
        let!(:another_invite) { another_topic.invite(coding_horror, 'jake@adventuretime.ooo') }
        let!(:user) { invite.redeem }

        it 'adds the user to the topic_users of the first topic' do
          topic.allowed_users.include?(user).should be_true
        end

        it 'adds the user to the topic_users of the second topic' do
          another_topic.allowed_users.include?(user).should be_true
        end

        it 'does not redeem the second invite' do
          another_invite.reload
          another_invite.should_not be_redeemed
        end

        context 'if they redeem the other invite afterwards' do

          before do
            @result = another_invite.redeem
          end

          it 'returns the same user' do
            @result.should == user
          end

          it 'marks the second invite as redeemed' do
            another_invite.reload
            another_invite.should be_redeemed
          end

        end
      end
    end
  end

  describe '.find_all_invites_from' do
    context 'with user that has invited' do
      it 'returns invites' do
        inviter = Fabricate(:user)
        invite = Fabricate(:invite, invited_by: inviter)

        invites = Invite.find_all_invites_from(inviter)

        expect(invites).to include invite
      end
    end

    context 'with user that has not invited' do
      it 'does not return invites' do
        user = Fabricate(:user)
        invite = Fabricate(:invite)

        invites = Invite.find_all_invites_from(user)

        expect(invites).to be_empty
      end
    end
  end

  describe '.find_redeemed_invites_from' do
    it 'returns redeemed invites only' do
      inviter = Fabricate(:user)
      pending_invite = Fabricate(
        :invite,
        invited_by: inviter,
        user_id: nil,
        email: 'pending@example.com'
      )
      redeemed_invite = Fabricate(
        :invite,
        invited_by: inviter,
        user_id: 123,
        email: 'redeemed@example.com'
      )

      invites = Invite.find_redeemed_invites_from(inviter)

      expect(invites).to have(1).items
      expect(invites.first).to eq redeemed_invite
    end
  end
end
