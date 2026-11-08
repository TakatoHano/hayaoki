Rails.application.routes.draw do
  get "/up" => "home#up"
  get "/" => "home#index"
end
