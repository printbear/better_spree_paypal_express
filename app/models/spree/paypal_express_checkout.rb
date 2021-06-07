module Spree
  class PaypalExpressCheckout < ActiveRecord::Base
    def actions
      %w{capture}
    end

    def can_capture?(payment)
      (payment.pending? || payment.checkout?) && authorized?
    end

    def authorized?
      !authorization_id.blank?
    end
  end
end
