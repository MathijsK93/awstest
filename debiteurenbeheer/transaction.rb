module Pay
	class Transaction
		def self.create(params)
			conn = Faraday.new(url: 'https://rest-api.pay.nl')
			response = conn.get('v5/Transaction/start/json?', params)
			response_body = JSON.parse(response.body)
			TransactionResponse.new(response_body)
		end

		class TransactionResponse < OpenStruct
			def success?
				request["result"] == "1"
			end

			def issuer_url
				transaction['paymentURL']
			end

			def order_id
				transaction['transactionId']
			end
		end
	end
end
