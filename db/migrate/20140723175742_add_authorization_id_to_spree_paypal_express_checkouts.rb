class AddAuthorizationIdToSpreePaypalExpressCheckouts < ActiveRecord::Migration
  def change
    add_column :spree_paypal_express_checkouts, :authorization_id, :string
    add_index :spree_paypal_express_checkouts, :authorization_id
  end
end
