include karax/prelude

import ../app/types
import ../app/auth_bridge
import brand


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
      # Avoid a Karax redraw on every keystroke. Rebinding `value`
      # during each input event can reset the browser caret to the
      # beginning, which makes typing/backspace appear reversed.
      # `change` commits the field on blur before a clicked submit
      # button handler runs, preserving native caret behavior.
      proc onchange(event: Event, node: VNode) =
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
          src = productMark,
          alt = productName
        )

        tdiv:
          strong:
            text productName
          span:
            text productTagline

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
              text "Please wait…"
            else:
              text "Sign in"

            proc onclick(event: Event, node: VNode) =
              discard loginApplication(state)

          tdiv(class = "auth-actions"):
            button(disabled = state.auth.loading):
              text "Create account"
              proc onclick(event: Event, node: VNode) =
                state.auth.error = ""
                state.auth.notice = ""
                state.auth.mode = amRegister

            button(disabled = state.auth.loading):
              text "Forgot password"
              proc onclick(event: Event, node: VNode) =
                state.auth.error = ""
                state.auth.notice = ""
                state.auth.mode = amForgotPassword

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
            button(disabled = state.auth.loading):
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
            button(disabled = state.auth.loading):
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

        of amVerifyEmail:
          h1:
            text "Verify your email"

          p(class = "auth-subtitle"):
            text "Open the link we sent"
            if state.auth.verificationEmailHint.len > 0:
              text " to "
              strong:
                text state.auth.verificationEmailHint
            text ". If it has not arrived, you can ask for another email when the wait ends."

          let waiting = state.auth.verificationSecondsLeft > 0
          button(class = "auth-primary", disabled = state.auth.loading or waiting):
            text "Resend verification email"
            proc onclick(event: Event, node: VNode) =
              discard resendVerificationApplication(state)

          p(class = "auth-countdown", role = "status"):
            if waiting:
              text "You can send another email in " & $state.auth.verificationSecondsLeft & " s."
            else:
              text "You can send another email now."

          tdiv(class = "auth-actions"):
            button(disabled = state.auth.loading):
              text "Back to sign in"
              proc onclick(event: Event, node: VNode) =
                backToSignIn(state)

        if state.auth.notice.len > 0:
          tdiv(class = "auth-notice"):
            text state.auth.notice

        if state.auth.error.len > 0:
          tdiv(class = "auth-error"):
            text state.auth.error
