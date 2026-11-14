module Api
  class DevicesController < ApplicationController
    # The devices you are signed in on.
    # @description Most recently used first. `device` is the browser's user
    #   agent when it signed in; `current` marks the device asking.
    # @response 200 #/components/schemas/Devices
    def index
      key = current_key
      render json: { devices: SignedInDevice.latest_first(Current.user!).map { SignedInDevice.as_json(it, key) } }
    end

    # Sign out one device.
    # @description Signs out the device with this id, which can be this one.
    # @response 204
    # @response 404 #/components/responses/NotFound
    def destroy
      id = Record.id(params[:id])
      removed = id && SignedInDevice.of(Current.user!).where(id:).delete
      raise Record::NotFound.new("Device", params[:id]) unless removed&.positive?

      head :no_content
    end

    # Sign out every other device.
    # @description Keeps this device signed in.
    # @response 204
    def destroy_others
      rodauth.remove_all_active_sessions_except_current
      head :no_content
    end

    private

    def rodauth = request.env.fetch("rodauth")

    def current_key
      key = rodauth.session[rodauth.session_id_session_key]
      key && rodauth.compute_hmac(key)
    end
  end
end
