require 'paypal-sdk-merchant'
module Spree
  class Gateway::PayPalExpress < Gateway
    def login
      ENV["#{business_entity_id.upcase}_PAYPAL_GATEWAY_LOGIN"]
    end

    def password
      ENV["#{business_entity_id.upcase}_PAYPAL_GATEWAY_PASSWORD"]
    end

    def signature
      ENV["#{business_entity_id.upcase}_PAYPAL_GATEWAY_SIGNATURE"]
    end

    def server
      ENV["#{business_entity_id.upcase}_PAYPAL_GATEWAY_SERVER"]
    end

    def solution
      ENV["#{business_entity_id.upcase}_PAYPAL_GATEWAY_SOLUTION"]
    end

    def landing_page
      ENV["#{business_entity_id.upcase}_PAYPAL_GATEWAY_LANDING_PAGE"]
    end

    def logourl
      ENV["#{business_entity_id.upcase}_PAYPAL_GATEWAY_LOGOURL"]
    end

    def use_authorization
      ENV["#{business_entity_id.upcase}_PAYPAL_GATEWAY_USE_AUTHORIZATION"] == 'true'
    end

    def provider
      ::PayPal::SDK.configure(
        :mode      => server.present? ? server : "sandbox",
        :username  => login,
        :password  => password,
        :signature => signature)
      provider_class.new
    end

    def auto_capture?
      !use_authorization
    end

    def supports?(source)
      true
    end

    def provider_class
      ::PayPal::SDK::Merchant::API
    end

    def method_type
      'paypal'
    end

    def capture(payment, express_checkout, gateway_options = {})
      pp_details_response = get_express_checkout_details(express_checkout.token)
      pp_payment_details = pp_details_response.get_express_checkout_details_response_details.PaymentDetails.first

      pp_request = provider.build_do_capture({
        :AuthorizationID => express_checkout.authorization_id,
        :Amount => {
          :currencyID => pp_payment_details.OrderTotal.currencyID,
          :value => payment.amount
        },
        :CompleteType => "Complete"
      })

      pp_response = provider.do_capture(pp_request)
      if pp_response.success?
        # Store transaction ID so we can refund payment if need be.
        transaction_id = pp_response.do_capture_response_details.payment_info.transaction_id
        express_checkout.update_column(:transaction_id, transaction_id)

        Class.new do
          def success?; true; end
          def authorization; nil; end
        end.new
      else
        class << pp_response
          def to_s
            errors.map(&:long_message).join(" ")
          end
        end
        pp_response
      end
    end

    def authorize(amount, express_checkout, gateway_options = {})
      do_express_checkout_payment(amount, express_checkout, "Authorization")
    end

    def purchase(amount, express_checkout, gateway_options = {})
      do_express_checkout_payment(amount, express_checkout, "Sale")
    end

    def void(express_checkout)
      pp_request = provider.build_do_void({:AuthorizationID => express_checkout.authorization_id})

      provider.do_void(pp_request)
    end

    def refund(payment, amount)
      refund_type = payment.amount == amount.to_f ? "Full" : "Partial"
      refund_transaction = provider.build_refund_transaction({
        :TransactionID => payment.source.transaction_id,
        :RefundType => refund_type,
        :Amount => {
          :currencyID => payment.currency,
          :value => amount },
        :RefundSource => "any" })
      refund_transaction_response = provider.refund_transaction(refund_transaction)
      if refund_transaction_response.success?
        payment.source.update_attributes({
          :refunded_at => Time.now,
          :refund_transaction_id => refund_transaction_response.RefundTransactionID,
          :state => "refunded",
          :refund_type => refund_type
        }, :without_protection => true)
      end
      refund_transaction_response
    end

    private
    def get_express_checkout_details(token)
      pp_request = provider.build_get_express_checkout_details({
        :Token => token
      })
      provider.get_express_checkout_details(pp_request)
    end

    def do_express_checkout_payment(amount, express_checkout, payment_action)
      pp_details_response = get_express_checkout_details(express_checkout.token)
      pp_payment_details = pp_details_response.get_express_checkout_details_response_details.PaymentDetails.first

      pp_request = provider.build_do_express_checkout_payment({
        :DoExpressCheckoutPaymentRequestDetails => {
          :PaymentAction => payment_action,
          :Token => express_checkout.token,
          :PayerID => express_checkout.payer_id,
          :PaymentDetails => [{
            :OrderTotal => {
              :currencyID => pp_payment_details.OrderTotal.currencyID,
              :value => amount / 100.0
            },
            :NotifyURL => pp_payment_details.NotifyURL
          }]

        }
      })

      pp_response = provider.do_express_checkout_payment(pp_request)
      if pp_response.success?
        pp_response_details = pp_response.do_express_checkout_payment_response_details
        transaction_id = pp_response_details.payment_info.first.transaction_id

        if pp_response_details.payment_info.first.pending_reason == "authorization"
          # Used authorization. Store transaction so that we can capture payment later.
          express_checkout.update_column(:authorization_id, transaction_id)
        else
          # Payment is completed. Did not use authorization.
          express_checkout.update_column(:transaction_id, transaction_id)
        end

        # This is rather hackish, required for payment/processing handle_response code.
        Class.new do
          def success?; true; end
          def authorization; nil; end
        end.new
      else
        class << pp_response
          def to_s
            errors.map(&:long_message).join(" ")
          end
        end
        pp_response
      end
    end
  end
end
