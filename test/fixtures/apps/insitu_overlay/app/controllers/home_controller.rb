class HomeController < ApplicationController
  def index
    render plain: I18n.t("hayaoki.hello", default: "ok")
  end

  def up
    head :ok
  end
end
