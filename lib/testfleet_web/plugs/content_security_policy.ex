defmodule TestFleetWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  The Content Security Policy of TestFleet's own pages: everything from this
  origin only, so markup that slipped through escaping could not load or run
  anything.

    * **Scripts:** the bundle, and the one inline script of the root layout, which
      carries the request's nonce (`assigns.csp_nonce`).
    * **Styles:** the bundle and `style` attributes, which templates use for
      widths and indentation.
    * **Frames, images, media:** this origin, where the run page embeds artifacts.
      Artifacts get their own, sandboxing policy (`TestFleetWeb.ArtifactResponse`).

  Not part of the `:artifacts` and API pipelines.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "media-src 'self' blob:",
        "font-src 'self' data:",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'self'"
      ],
      "; "
    )
  end
end
