import React from "react";
import { useTranslation } from "react-i18next";
import { PasswordResetDialog as PasswordResetDialogView } from "@jordiorriols/ui";
import { usePasswordResetForm } from "@jordiorriols/ui/hooks";
import { useData } from "@/data/DataProvider";

export function PasswordResetDialog() {
  const { t } = useTranslation();
  const { passwordRecovery, updatePassword } = useData();
  const form = usePasswordResetForm({
    isOpen: passwordRecovery,
    updatePassword,
    messages: {
      passwordTooShort: t("auth.passwordTooShort"),
      passwordsDoNotMatch: t("auth.passwordsDoNotMatch"),
    },
  });
  return (
    <PasswordResetDialogView
      isOpen={passwordRecovery}
      form={form}
      labels={{
        title: t("auth.resetPasswordTitle"),
        description: t("auth.resetPasswordDescription"),
        newPassword: t("auth.newPassword"),
        confirmPassword: t("auth.confirmPassword"),
        updatePassword: t("auth.updatePassword"),
      }}
    />
  );
}
