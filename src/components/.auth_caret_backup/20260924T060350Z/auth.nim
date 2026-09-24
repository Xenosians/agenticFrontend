include karax/prelude

import ../app/types
import ../app/auth_bridge


proc authInput(
  labelText: string,
  inputType: string,
  placeholderText: string,
  valueText: string,
  onChange: proc(value: string) {.closure.}
): VNode =
  result = buildHtml(
    label(class = "auth-field")
  ):
    span:
      text labelText

    input(
      `type` = cstring(inputType),
      placeholder = cstring(placeholderText),
      value = cstring(valueText)
    ):
      proc oninput(event: Event, node: VNode) =
        onChange($node.value)


proc renderAuthScreen*(
  state: AppState
): VNode =
  result = buildHtml(
    main(class = "auth-shell")
  ):
    section(class = "auth-card"):
      tdiv(class = "auth-brand"):
        img(
          class = "brand-logo",
          src = "./assets/hydra.svg",
          alt = "Agentic Hydra"
        )

        tdiv:
          strong:
            text "Agentic"
          span:
            text "Developer Hub"

      if not state.auth.checked:
        tdiv(class = "auth-status"):
          text "Restoring session..."

      else:
        case state.auth.mode

        of amLogin:
          h1:
            text "Sign in"

          p(class = "auth-subtitle"):
            text "Use your application account to access owned chats and governed jobs."

          authInput(
            "Email",
            "email",
            "you@example.com",
            state.auth.emailDraft,
            proc(value: string) = state.auth.emailDraft = value
          )

          authInput(
            "Password",
            "password",
            "Password",
            state.auth.passwordDraft,
            proc(value: string) = state.auth.passwordDraft = value
          )

          button(class = "auth-primary", disabled = state.auth.loading):
            if state.auth.loading:
              text "Signing in..."
            else:
              text "Sign in"

            proc onclick(event: Event, node: VNode) =
              discard loginApplication(state)

          tdiv(class = "auth-actions"):
            button:
              text "Create account"
              proc onclick(event: Event, node: VNode) =
                state.auth.error = ""
                state.auth.mode = amRegister

            button:
              text "Forgot password"
              proc onclick(event: Event, node: VNode) =
                state.auth.error = ""
                state.auth.mode = amForgotPassword

            button:
              text "Resend verification"
              proc onclick(event: Event, node: VNode) =
                discard resendVerificationApplication(state)

        of amRegister:
          h1:
            text "Create account"

          p(class = "auth-subtitle"):
            text "This account identifies the person requesting AI and ITSM operations."

          authInput(
            "Display name",
            "text",
            "Your name",
            state.auth.displayNameDraft,
            proc(value: string) = state.auth.displayNameDraft = value
          )

          authInput(
            "Email",
            "email",
            "you@example.com",
            state.auth.emailDraft,
            proc(value: string) = state.auth.emailDraft = value
          )

          authInput(
            "Password",
            "password",
            "Choose a password",
            state.auth.passwordDraft,
            proc(value: string) = state.auth.passwordDraft = value
          )

          button(class = "auth-primary", disabled = state.auth.loading):
            text "Register"
            proc onclick(event: Event, node: VNode) =
              discard registerApplication(state)

          tdiv(class = "auth-actions"):
            button:
              text "Back to sign in"
              proc onclick(event: Event, node: VNode) =
                state.auth.error = ""
                state.auth.mode = amLogin

        of amForgotPassword:
          h1:
            text "Reset password"

          p(class = "auth-subtitle"):
            text "Enter your email. If the account exists, the backend mailer will send a reset link."

          authInput(
            "Email",
            "email",
            "you@example.com",
            state.auth.emailDraft,
            proc(value: string) = state.auth.emailDraft = value
          )

          button(class = "auth-primary", disabled = state.auth.loading):
            text "Send reset email"
            proc onclick(event: Event, node: VNode) =
              discard forgotPasswordApplication(state)

          tdiv(class = "auth-actions"):
            button:
              text "Back to sign in"
              proc onclick(event: Event, node: VNode) =
                state.auth.error = ""
                state.auth.mode = amLogin

        of amResetPassword:
          h1:
            text "Choose new password"

          p(class = "auth-subtitle"):
            text "This reset link is single-purpose and expires automatically."

          authInput(
            "New password",
            "password",
            "New password",
            state.auth.newPasswordDraft,
            proc(value: string) = state.auth.newPasswordDraft = value
          )

          button(class = "auth-primary", disabled = state.auth.loading):
            text "Reset password"
            proc onclick(event: Event, node: VNode) =
              discard resetPasswordApplication(state)

        if state.auth.notice.len > 0:
          tdiv(class = "auth-notice"):
            text state.auth.notice

        if state.auth.error.len > 0:
          tdiv(class = "auth-error"):
            text state.auth.error
