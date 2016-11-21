require 'spec_helper'

describe Import::BitbucketController do
  include ImportSpecHelper

  let(:user) { create(:user) }
  let(:token) { "asdasd12345" }
  let(:secret) { "sekrettt" }
  let(:refresh_token) { SecureRandom.hex(15) }
  let(:access_params) { { bitbucket_access_token: token, bitbucket_access_token_secret: secret } }

  def assign_session_tokens
    session[:bitbucket_token] = token
  end

  before do
    sign_in(user)
    allow(controller).to receive(:bitbucket_import_enabled?).and_return(true)
  end

  describe "GET callback" do
    before do
      session[:oauth_request_token] = {}
    end

    it "updates access token" do
      expires_at = Time.now + 1.day
      expires_in = 1.day
      access_token = double(token: token,
                            secret: secret,
                            expires_at: expires_at,
                            expires_in: expires_in,
                            refresh_token: refresh_token)
      allow_any_instance_of(OAuth2::Client).
        to receive(:get_token).and_return(access_token)
      stub_omniauth_provider('bitbucket')

      get :callback

      expect(session[:bitbucket_token]).to eq(token)
      expect(session[:bitbucket_refresh_token]).to eq(refresh_token)
      expect(session[:bitbucket_expires_at]).to eq(expires_at)
      expect(session[:bitbucket_expires_in]).to eq(expires_in)
      expect(controller).to redirect_to(status_import_bitbucket_url)
    end
  end

  describe "GET status" do
    before do
      @repo = double(slug: 'vim', owner: 'asd', full_name: 'asd/vim', "valid?" => true)
      assign_session_tokens
    end

    it "assigns variables" do
      @project = create(:project, import_type: 'bitbucket', creator_id: user.id)
      allow_any_instance_of(Bitbucket::Client).to receive(:repos).and_return([@repo])

      get :status

      expect(assigns(:already_added_projects)).to eq([@project])
      expect(assigns(:repos)).to eq([@repo])
      expect(assigns(:incompatible_repos)).to eq([])
    end

    it "does not show already added project" do
      @project = create(:project, import_type: 'bitbucket', creator_id: user.id, import_source: 'asd/vim')
      allow_any_instance_of(Bitbucket::Client).to receive(:repos).and_return([@repo])

      get :status

      expect(assigns(:already_added_projects)).to eq([@project])
      expect(assigns(:repos)).to eq([])
    end
  end

  describe "POST create" do
    let(:bitbucket_username) { user.username }

    let(:bitbucket_user) do
      { user: { username: bitbucket_username } }.with_indifferent_access
    end

    let(:bitbucket_repo) do
      { slug: "vim", owner: bitbucket_username }.with_indifferent_access
    end

    before do
      allow(Gitlab::BitbucketImport::KeyAdder).
        to receive(:new).with(bitbucket_repo, user, access_params).
        and_return(double(execute: true))

      stub_client(user: bitbucket_user, project: bitbucket_repo)
      assign_session_tokens
    end

    context "when the repository owner is the Bitbucket user" do
      context "when the Bitbucket user and GitLab user's usernames match" do
        it "takes the current user's namespace" do
          expect(Gitlab::BitbucketImport::ProjectCreator).
            to receive(:new).with(bitbucket_repo, user.namespace, user, access_params).
            and_return(double(execute: true))

          post :create, format: :js
        end
      end

      context "when the Bitbucket user and GitLab user's usernames don't match" do
        let(:bitbucket_username) { "someone_else" }

        it "takes the current user's namespace" do
          expect(Gitlab::BitbucketImport::ProjectCreator).
            to receive(:new).with(bitbucket_repo, user.namespace, user, access_params).
            and_return(double(execute: true))

          post :create, format: :js
        end
      end
    end

    context "when the repository owner is not the Bitbucket user" do
      let(:other_username) { "someone_else" }

      before do
        bitbucket_repo["owner"] = other_username
      end

      context "when a namespace with the Bitbucket user's username already exists" do
        let!(:existing_namespace) { create(:namespace, name: other_username, owner: user) }

        context "when the namespace is owned by the GitLab user" do
          it "takes the existing namespace" do
            expect(Gitlab::BitbucketImport::ProjectCreator).
              to receive(:new).with(bitbucket_repo, existing_namespace, user, access_params).
              and_return(double(execute: true))

            post :create, format: :js
          end
        end

        context "when the namespace is not owned by the GitLab user" do
          before do
            existing_namespace.owner = create(:user)
            existing_namespace.save
          end

          it "doesn't create a project" do
            expect(Gitlab::BitbucketImport::ProjectCreator).
              not_to receive(:new)

            post :create, format: :js
          end
        end
      end

      context "when a namespace with the Bitbucket user's username doesn't exist" do
        context "when current user can create namespaces" do
          it "creates the namespace" do
            expect(Gitlab::BitbucketImport::ProjectCreator).
              to receive(:new).and_return(double(execute: true))

            expect { post :create, format: :js }.to change(Namespace, :count).by(1)
          end

          it "takes the new namespace" do
            expect(Gitlab::BitbucketImport::ProjectCreator).
              to receive(:new).with(bitbucket_repo, an_instance_of(Group), user, access_params).
              and_return(double(execute: true))

            post :create, format: :js
          end
        end

        context "when current user can't create namespaces" do
          before do
            user.update_attribute(:can_create_group, false)
          end

          it "doesn't create the namespace" do
            expect(Gitlab::BitbucketImport::ProjectCreator).
              to receive(:new).and_return(double(execute: true))

            expect { post :create, format: :js }.not_to change(Namespace, :count)
          end

          it "takes the current user's namespace" do
            expect(Gitlab::BitbucketImport::ProjectCreator).
              to receive(:new).with(bitbucket_repo, user.namespace, user, access_params).
              and_return(double(execute: true))

            post :create, format: :js
          end
        end
      end
    end
  end
end
