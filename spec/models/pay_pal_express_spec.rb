require 'spec_helper'

describe Spree::Gateway::PayPalExpress do
  let(:gateway) { Spree::Gateway::PayPalExpress.create!(name: "PayPalExpress", environment: Rails.env) }

  let(:payment) do
    FactoryGirl.create(:payment, payment_method: gateway, amount: 10).tap do |payment|
      payment.stub source: mock_model(
        Spree::PaypalExpressCheckout,
        token: 'fake_token',
        payer_id: 'fake_payer_id',
        update_column: true
      )
    end
  end

  let(:provider) do
    double('Provider').tap do |provider|
      gateway.stub(provider: provider)
    end
  end

  context "payment purchase" do
    before do
      provider.should_receive(:build_get_express_checkout_details).with({
        :Token => 'fake_token'
      }).and_return(pp_details_request = double)

      pp_details_response = double(
        :get_express_checkout_details_response_details => double(
          :PaymentDetails => [
            double(
              :OrderTotal => double(
                :currencyID => "USD",
                :value => "10.00"
              ),
              :NotifyURL => ""
            )
          ]
        )
      )

      provider.should_receive(:get_express_checkout_details).
        with(pp_details_request).
        and_return(pp_details_response)

      provider.should_receive(:build_do_express_checkout_payment).with({
        :DoExpressCheckoutPaymentRequestDetails => {
          :PaymentAction => action,
          :Token => "fake_token",
          :PayerID => "fake_payer_id",
          :PaymentDetails => [{
            :OrderTotal => {
              :currencyID => "USD",
              :value => 10.0
            },
            :NotifyURL => ""
          }]
        }
      })
    end

    describe "#purchase" do
      let(:action) { "Sale" }

      # Test for #11
      it "succeeds" do
        response = double('pp_response', :success? => true)
        response.stub_chain("do_express_checkout_payment_response_details.payment_info.first.transaction_id").and_return '12345'
        response.stub_chain("do_express_checkout_payment_response_details.payment_info.first.pending_reason").and_return nil
        provider.should_receive(:do_express_checkout_payment).and_return(response)
        expect{ payment.purchase! }.not_to raise_error
      end

      # Test for #4
      it "fails" do
        response = double('pp_response', :success? => false,
                          :errors => [double('pp_response_error', :long_message => "An error goes here.")])
        provider.should_receive(:do_express_checkout_payment).and_return(response)
        expect{ payment.purchase! }.to raise_error(Spree::Core::GatewayError, "An error goes here.")
      end
    end

    describe "#authorize" do
      let(:action) { "Authorization" }

      it "succeeds" do
        response = double('pp_response', :success? => true)
        response.stub_chain("do_express_checkout_payment_response_details.payment_info.first.transaction_id").and_return '12345'
        response.stub_chain("do_express_checkout_payment_response_details.payment_info.first.pending_reason").and_return "authorization"
        provider.should_receive(:do_express_checkout_payment).and_return(response)
        expect{ payment.authorize! }.not_to raise_error
      end

      it "fails" do
        response = double('pp_response', :success? => false,
                          :errors => [double('pp_response_error', :long_message => "An error goes here.")])
        provider.should_receive(:do_express_checkout_payment).and_return(response)
        expect{ payment.authorize! }.to raise_error(Spree::Core::GatewayError, "An error goes here.")
      end
    end
  end

  describe "#capture" do
    before do
      gateway.stub(:create_profile)
      gateway.stub(:payment_profiles_supported?).and_return(true)

      payment.source.stub(:authorization_id).and_return("54321")

      provider.should_receive(:build_get_express_checkout_details).with({
        :Token => 'fake_token'
      }).and_return(pp_details_request = double)

      pp_details_response = double(
        :get_express_checkout_details_response_details => double(
          :PaymentDetails => [
            double(
              :OrderTotal => double(
                :currencyID => "USD",
                :value => "10.00"
              ),
              :NotifyURL => ""
            )
          ]
        )
      )

      provider.should_receive(:get_express_checkout_details).
        with(pp_details_request).
        and_return(pp_details_response)

      provider.should_receive(:build_do_capture).with({
        :AuthorizationID => "54321",
        :Amount => {
          :currencyID => "USD",
          :value => 10.0
        },
        :CompleteType => "Complete"
      })
    end

    it "succeeds" do
      response = double('pp_response', :success? => true)
      response.stub_chain("do_capture_response_details.payment_info.transaction_id").and_return '12345'
      provider.should_receive(:do_capture).and_return(response)
      expect{ payment.capture! }.not_to raise_error
    end

    it "fails" do
      response = double(
        'pp_response',
        success?: false,
        errors: [double('pp_response_error', long_message: "An error goes here.")]
      )
      provider.should_receive(:do_capture).and_return(response)
      expect{ payment.capture! }.to raise_error(Spree::Core::GatewayError, "An error goes here.")
    end
  end
end
