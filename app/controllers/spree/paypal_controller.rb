module Spree
  class PaypalController < StoreController
    ssl_allowed

    before_filter :check_authorization

    def express
      items = order.line_items.map(&method(:line_item))

      tax_adjustments = order.adjustments.tax
      shipping_adjustments = order.adjustments.shipping

      order.adjustments.eligible.each do |adjustment|
        next if (tax_adjustments + shipping_adjustments).include?(adjustment)
        items << {
          :Name => adjustment.label,
          :Quantity => 1,
          :Amount => {
            :currencyID => order.currency,
            :value => adjustment.amount
          }
        }
      end

      items << {
        :Name => 'Existing Payment',
        :Quantity => 1,
        :Amount => {
          :currencyID => order.currency,
          :value => -existing_payment
        }
      }

      # Because PayPal doesn't accept $0 items at all.
      # See #10
      # https://cms.paypal.com/uk/cgi-bin/?cmd=_render-content&content_ID=developer/e_howto_api_ECCustomizing
      # "It can be a positive or negative value but not zero."
      items.reject! do |item|
        item[:Amount][:value].zero?
      end
      pp_request = provider.build_set_express_checkout(express_checkout_request_details(order, items))

      begin
        pp_response = provider.set_express_checkout(pp_request)
        if pp_response.success?
          redirect_to provider.express_checkout_url(pp_response, :useraction => 'commit')
        else
          message = pp_response.errors.map(&:long_message).join(" ")
          Bugsnag.notify(RuntimeError.new(message))
          flash[:error] = Spree.t('flash.generic_error', :scope => 'paypal', :reasons => message)
          redirect_to checkout_state_path(:payment)
        end
      rescue SocketError => e
        Bugsnag.notify(e)
        flash[:error] = Spree.t('flash.connection_failed', :scope => 'paypal')
        redirect_to checkout_state_path(:payment)
      end
    end

    def confirm
      payment = order.payments.create!({
        :source => Spree::PaypalExpressCheckout.create({
          :token => params[:token],
          :payer_id => params[:PayerID]
        }, :without_protection => true),
        :amount => total_amount,
        :payment_method => payment_method
      }, :without_protection => true)

      if order.completed?
        # Order is already completed. Adding an additional payment.
        payment.process!
        flash[:notice] = 'Payment successfully added'
      else
        # Otherwise we should advance through the payment state.
        order.next
        if order.completed?
          flash.notice = Spree.t(:order_processed_successfully)
          flash[:commerce_tracking] = "nothing special"
        end
      end

      redirect_to_order(order.state)
    end

    def cancel
      redirect_to checkout_state_path(order.state, paypal_cancel_token: params[:token])
    end

    private
    def redirect_to_order state=:payment
      if order.completed?
        redirect_to completion_route
      else
        redirect_to checkout_state_path(state)
      end
    end

    def order
      @order ||= begin
        if order_id = params[:order_id]
          Order.find_by_number!(order_id)
        else
          current_order || raise(ActiveRecord::RecordNotFound)
        end
      end
    end

    def check_authorization
      authorize! :read, order, session[:access_token]
    end

    def line_item(item)
      {
          :Name => "#{item.quantity} #{item.name}",
          :Number => item.variant.sku,
          :Quantity => 1,
          :Amount => {
              :currencyID => item.order.currency,
              :value => item.amount
          },
          :ItemCategory => "Physical"
      }
    end

    def express_checkout_request_details order, items
      { :SetExpressCheckoutRequestDetails => {
          :InvoiceID => order.number,
          :ReturnURL => confirm_paypal_url(:payment_method_id => params[:payment_method_id], :order_id => order.number, :utm_nooverride => 1),
          :CancelURL =>  cancel_paypal_url,
          :SolutionType => payment_method.preferred_solution.present? ? payment_method.preferred_solution : "Mark",
          :LandingPage => payment_method.preferred_landing_page.present? ? payment_method.preferred_landing_page : "Billing",
          :cppheaderimage => payment_method.preferred_logourl.present? ? payment_method.preferred_logourl : "",
          :NoShipping => 1,
          :PaymentDetails => [payment_details(items)]
      }}
    end

    def payment_method
      Spree::PaymentMethod.find(params[:payment_method_id])
    end

    def provider
      payment_method.provider
    end

    def existing_payment
      order.authorized_payment_total
    end

    def total_amount
      order.total - existing_payment
    end

    def payment_details items
      item_sum = items.sum { |i| i[:Quantity] * i[:Amount][:value] }
      if item_sum.zero?
        # Paypal does not support no items or a zero dollar ItemTotal
        # This results in the order summary being simply "Current purchase"
        {
          :OrderTotal => {
            :currencyID => order.currency,
            :value => total_amount
          }
        }
      else
        {
          :OrderTotal => {
            :currencyID => order.currency,
            :value => total_amount
          },
          :ItemTotal => {
            :currencyID => order.currency,
            :value => item_sum
          },
          :ShippingTotal => {
            :currencyID => order.currency,
            :value => order.ship_total
          },
          :TaxTotal => {
            :currencyID => order.currency,
            :value => order.tax_total
          },
          :ShipToAddress => address_options,
          :PaymentDetailsItem => items,
          :ShippingMethod => "Shipping Method Name Goes Here",
          :PaymentAction => payment_action
        }
      end
    end

    def payment_action
      payment_method.auto_capture? ? "Authorization" : "Sale"
    end

    def address_options
      return {} unless address_required?

      {
          :Name => order.bill_address.try(:full_name),
          :Street1 => order.bill_address.address1,
          :Street2 => order.bill_address.address2,
          :CityName => order.bill_address.city,
          # :phone => order.bill_address.phone,
          :StateOrProvince => order.bill_address.state_text,
          :Country => order.bill_address.country.iso,
          :PostalCode => order.bill_address.zipcode
      }
    end

    def completion_route
      order_path(order, :token => order.token)
    end

    def address_required?
      payment_method.preferred_solution.eql?('Sole')
    end
  end
end
