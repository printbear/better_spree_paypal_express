Spree::Admin::PaymentsController.class_eval do
  def paypal_refund
    if request.get?
      if @payment.source.state == 'refunded'
        flash[:error] = Spree.t(:already_refunded, :scope => 'paypal')
        redirect_to admin_order_payment_path(@order, @payment)
      end
    elsif request.post?
      begin
        @payment.refund!(params[:refund_amount].to_f)
        flash[:success] = Spree.t(:refund_successful, :scope => 'paypal')
        redirect_to admin_order_payments_path(@order)
      rescue Core::GatewayError => e
        flash.now[:error] = Spree.t(:refund_unsuccessful, :scope => 'paypal') + " (#{e})"
        render
      end
    end
  end
end
