import React from "react";
import { useTranslation } from "react-i18next";
import { AuthDialog } from "@jordiorriols/ui";
import { useData } from "@/data/DataProvider";

export function useAuthDialogProps() {
  const { t } = useTranslation();
  const actions = useData();
  return {
    actions,
    messages: {
      passwordResetSent: t("auth.passwordResetSent"),
      checkEmail: t("auth.checkEmail"),
    },
    formatError: (message: string) => message,
    labels: {
      signInTitle: t("auth.signInTitle"),
      signUpTitle: t("auth.signUpTitle"),
      forgotPasswordTitle: t("auth.forgotPasswordTitle"),
      description: t("auth.description"),
      forgotPasswordDescription: t("auth.forgotPasswordDescription"),
      continueWithGitHub: t("auth.continueWithGitHub"),
      email: t("auth.email"),
      password: t("auth.password"),
      forgotPassword: t("auth.forgotPassword"),
      switchToSignUp: t("auth.switchToSignUp"),
      switchToSignIn: t("auth.switchToSignIn"),
      backToSignIn: t("auth.backToSignIn"),
      cancel: t("auth.cancel"),
      signIn: t("auth.signIn"),
      signUp: t("auth.signUp"),
      sendResetEmail: t("auth.sendResetEmail"),
    },
  };
}

export function LoginDialog(props: {
  isOpen: boolean;
  onClose: () => void;
  initialMode?: "signIn" | "signUp";
}) {
  const config = useAuthDialogProps();
  return <AuthDialog {...config} {...props} />;
}
