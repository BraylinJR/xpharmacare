# ═══════════════════════════════════════════════════════════════
# XFarmaCare — Modelado de Uplift e Inferencia Causal
# ═══════════════════════════════════════════════════════════════
#
# ESTE ES EL DIFERENCIADOR.
#
# No basta con predecir quién se va. El valor real está en saber
# A QUIÉN VALE LA PENA RETENER.
#
# Este script implementa:
#   1. Causal Forest (grf) para estimar el efecto individual
#      del tratamiento (CATE) de cada cliente.
#   2. Clasificación en 4 tipos de respuesta:
#      - Persuadibles: solo se quedan SI reciben la oferta
#      - Sure Things: se quedan con o sin oferta (no gastar)
#      - Lost Causes: se van con o sin oferta (no gastar)
#      - Sleeping Dogs: se van PORQUE reciben la oferta (peligro)
#   3. Cálculo del Value-LIFT: impacto en CLV de cada intervención
#
# Basado en: Ascarza (2018) "Retention Futility" - JMR
#
# Input:  data/fact_campanas_retencion.csv (datos del experimento A/B)
#         outputs/dataset_analitico_clientes.csv
# Output: outputs/output_uplift_scores.csv
# ═══════════════════════════════════════════════════════════════

# --- Librerías ---
# install.packages(c("grf", "dplyr", "readr", "ggplot2", "pROC"))
library(grf)       # Causal forests de Athey & Wager
library(dplyr)
library(readr)
library(ggplot2)

cat("═══════════════════════════════════════════════════\n")
cat("  XFarmaCare — Modelado de Uplift (Causal Forest)\n")
cat("═══════════════════════════════════════════════════\n\n")

# --- Cargar datos del experimento A/B ---
campanas  <- read_csv("data/fact_campanas_retencion.csv", show_col_types = FALSE)
analitico <- read_csv("outputs/dataset_analitico_clientes.csv", show_col_types = FALSE)

cat(sprintf("Registros del experimento: %d\n", nrow(campanas)))
cat(sprintf("  Tratamiento: %d | Control: %d\n",
            sum(campanas$grupo_experimento == "Tratamiento"),
            sum(campanas$grupo_experimento == "Control")))
cat(sprintf("  Tasa de churn global: %.1f%%\n",
            mean(campanas$hizo_churn_post_campana) * 100))

# ═══════════════════════════════════════════════════════════════
# PREPARACIÓN DE DATOS PARA EL CAUSAL FOREST
# ═══════════════════════════════════════════════════════════════

cat("\nPreparando datos para causal forest...\n")

# Unir datos del experimento con features del cliente
df_uplift <- campanas %>%
  left_join(analitico, by = "customer_id") %>%
  filter(!is.na(total_transacciones))  # Solo clientes con historial

cat(sprintf("Clientes con datos completos: %d\n", nrow(df_uplift)))

# Variables de tratamiento (W) y resultado (Y)
W <- as.numeric(df_uplift$grupo_experimento == "Tratamiento")  # 1 = tratamiento
Y <- as.numeric(!df_uplift$hizo_churn_post_campana)            # 1 = se quedó (retención)

# Features (X) - las mismas del modelo de churn
feature_names <- c(
  "edad", "total_transacciones", "total_gastado_dop",
  "promedio_ticket_dop", "frecuencia_mensual", "recencia_dias",
  "productos_distintos", "canales_usados", "descuento_promedio",
  "tendencia_gasto", "compras_receta_recurrente",
  "total_interacciones", "ratio_negatividad", "estrellas_promedio",
  "tasa_adherencia_promedio", "dias_gap_promedio", "ratio_retraso"
)

# Seleccionar solo features disponibles
feature_names <- feature_names[feature_names %in% names(df_uplift)]
X <- as.matrix(df_uplift[, feature_names])

# Reemplazar NA con 0
X[is.na(X)] <- 0

cat(sprintf("Features: %d\n", ncol(X)))
cat(sprintf("Tratados: %d | Control: %d\n", sum(W), length(W) - sum(W)))

# ═══════════════════════════════════════════════════════════════
# ENTRENAMIENTO DEL CAUSAL FOREST
# ═══════════════════════════════════════════════════════════════

cat("\nEntrenando Causal Forest (Wager & Athey)...\n")
cat("Esto puede tomar unos minutos...\n\n")

# El causal forest estima el CATE (Conditional Average Treatment Effect)
# para cada individuo. Es decir, cuánto cambia su probabilidad de
# retención SI recibe la oferta vs si NO la recibe.

cf <- causal_forest(
  X = X,
  Y = Y,
  W = W,
  num.trees = 2000,
  min.node.size = 15,
  honesty = TRUE,            # Honest estimation (split sample)
  seed = 42
)

cat("Causal Forest entrenado.\n")

# ═══════════════════════════════════════════════════════════════
# ESTIMACIÓN DEL EFECTO INDIVIDUAL (CATE)
# ═══════════════════════════════════════════════════════════════

cat("\nEstimando efectos individuales del tratamiento (CATE)...\n")

# CATE > 0 → la oferta AUMENTA la retención (persuadible)
# CATE ≈ 0 → la oferta no cambia nada (sure thing o lost cause)
# CATE < 0 → la oferta REDUCE la retención (sleeping dog)

predicciones <- predict(cf, estimate.variance = TRUE)
df_uplift$cate <- predicciones$predictions
df_uplift$cate_se <- sqrt(predicciones$variance.estimates)

cat(sprintf("CATE promedio: %.4f\n", mean(df_uplift$cate)))
cat(sprintf("CATE mediana:  %.4f\n", median(df_uplift$cate)))
cat(sprintf("Rango: [%.4f, %.4f]\n", min(df_uplift$cate), max(df_uplift$cate)))

# ═══════════════════════════════════════════════════════════════
# CLASIFICACIÓN EN 4 TIPOS DE RESPUESTA
# ═══════════════════════════════════════════════════════════════

cat("\nClasificando clientes en tipos de respuesta...\n")

# Para clasificar, necesitamos estimar tanto la probabilidad de churn
# SIN tratamiento como el CATE.

# Probabilidad base de retención (sin tratamiento)
# La estimamos del grupo control
control_data <- df_uplift %>% filter(grupo_experimento == "Control")
prob_retencion_base <- mean(control_data$hizo_churn_post_campana == FALSE)

# Clasificación basada en CATE y probabilidad base
df_uplift <- df_uplift %>%
  mutate(
    uplift_score = round(cate, 4),

    tipo_respuesta = case_when(
      # Persuadible: CATE positivo significativo
      cate > 0.05 ~ "Persuadible",

      # Sleeping Dog: CATE negativo (la oferta les hace irse)
      cate < -0.03 ~ "Sleeping Dog",

      # Sure Thing: no churneó Y CATE bajo → se queda sin oferta
      hizo_churn_post_campana == FALSE & abs(cate) <= 0.05 ~ "Sure Thing",

      # Lost Cause: churneó Y CATE bajo → se va con o sin oferta
      hizo_churn_post_campana == TRUE & abs(cate) <= 0.05 ~ "Lost Cause",

      # Default
      TRUE ~ "Indeterminado"
    )
  )

# Resumen
cat("\nDistribución de tipos de respuesta:\n")
resumen_tipos <- df_uplift %>%
  group_by(tipo_respuesta) %>%
  summarise(
    n = n(),
    pct = round(n() / nrow(df_uplift) * 100, 1),
    cate_promedio = round(mean(cate), 4),
    tasa_churn = round(mean(hizo_churn_post_campana) * 100, 1),
    .groups = "drop"
  ) %>%
  arrange(desc(cate_promedio))

print(resumen_tipos)

# ═══════════════════════════════════════════════════════════════
# IMPORTANCIA DE VARIABLES EN EL UPLIFT
# ═══════════════════════════════════════════════════════════════

cat("\nImportancia de variables para el uplift:\n")

var_imp <- variable_importance(cf)
imp_df <- data.frame(
  feature = feature_names,
  importancia = round(as.numeric(var_imp), 4)
) %>%
  arrange(desc(importancia))

print(head(imp_df, 10))

# ═══════════════════════════════════════════════════════════════
# ANÁLISIS DE AHORRO POR TARGETING INTELIGENTE
# ═══════════════════════════════════════════════════════════════

cat("\n═══════════════════════════════════════════════════\n")
cat("  ANÁLISIS DE AHORRO — TARGETING INTELIGENTE\n")
cat("═══════════════════════════════════════════════════\n\n")

costo_oferta <- 500  # DOP promedio por oferta

# Escenario 1: Targeting a TODOS (enfoque ingenuo)
n_total <- nrow(df_uplift)
costo_todos <- n_total * costo_oferta
retenidos_extra_todos <- sum(df_uplift$cate > 0) * mean(df_uplift$cate[df_uplift$cate > 0])

# Escenario 2: Targeting solo a PERSUADIBLES (enfoque uplift)
persuadibles <- df_uplift %>% filter(tipo_respuesta == "Persuadible")
n_persuadibles <- nrow(persuadibles)
costo_persuadibles <- n_persuadibles * costo_oferta
retenidos_extra_uplift <- n_persuadibles * mean(persuadibles$cate)

# Escenario 3: Targeting a los de MAYOR RIESGO (enfoque churn tradicional)
top_riesgo <- df_uplift %>%
  arrange(desc(hizo_churn_post_campana)) %>%
  head(n_persuadibles)
costo_riesgo <- nrow(top_riesgo) * costo_oferta

cat(sprintf("Costo por oferta: RD$ %s\n\n", format(costo_oferta, big.mark = ",")))

cat("Escenario 1 — Contactar a TODOS:\n")
cat(sprintf("  Clientes: %s | Costo: RD$ %s\n",
            format(n_total, big.mark = ","),
            format(costo_todos, big.mark = ",")))
cat(sprintf("  Incluye %d Sleeping Dogs (empeoran con la oferta)\n\n",
            sum(df_uplift$tipo_respuesta == "Sleeping Dog")))

cat("Escenario 2 — Solo PERSUADIBLES (uplift):\n")
cat(sprintf("  Clientes: %s | Costo: RD$ %s\n",
            format(n_persuadibles, big.mark = ","),
            format(costo_persuadibles, big.mark = ",")))
cat(sprintf("  Ahorro vs contactar todos: RD$ %s (%.0f%% menos)\n\n",
            format(costo_todos - costo_persuadibles, big.mark = ","),
            (1 - costo_persuadibles / costo_todos) * 100))

cat("Escenario 3 — Top RIESGO de churn (enfoque tradicional):\n")
cat(sprintf("  Mismo número de contactos (%s) pero peor targeting\n",
            format(n_persuadibles, big.mark = ",")))
cat("  Incluye clientes que se iban a ir de todos modos (Lost Causes)\n")
cat("  y clientes que se iban a quedar sin oferta (Sure Things)\n")

cat(sprintf("\n→ AHORRO NETO por usar Uplift vs masa: RD$ %s DOP\n",
            format(costo_todos - costo_persuadibles, big.mark = ",")))

# ═══════════════════════════════════════════════════════════════
# EXTENDER A TODA LA CARTERA
# ═══════════════════════════════════════════════════════════════

cat("\nExtendiendo predicciones a toda la cartera...\n")

# Preparar features de todos los clientes
X_todos <- analitico[, feature_names]
X_todos[is.na(X_todos)] <- 0
X_todos <- as.matrix(X_todos)

# Predecir CATE para todos
pred_todos <- predict(cf, newdata = X_todos, estimate.variance = TRUE)

output_uplift <- data.frame(
  customer_id = analitico$customer_id,
  uplift_score = round(pred_todos$predictions, 4),
  uplift_se = round(sqrt(pred_todos$variance.estimates), 4)
) %>%
  mutate(
    tipo_respuesta = case_when(
      uplift_score > 0.05  ~ "Persuadible",
      uplift_score < -0.03 ~ "Sleeping Dog",
      uplift_score >= 0    ~ "Sure Thing",
      TRUE                 ~ "Lost Cause"
    ),
    confianza = case_when(
      abs(uplift_score) > 2 * uplift_se ~ "Alta",
      abs(uplift_score) > 1 * uplift_se ~ "Media",
      TRUE                               ~ "Baja"
    ),
    fecha_calculo = Sys.Date()
  )

cat(sprintf("Predicciones generadas para %s clientes.\n",
            format(nrow(output_uplift), big.mark = ",")))

cat("\nDistribución final de tipos:\n")
print(table(output_uplift$tipo_respuesta))

# ═══════════════════════════════════════════════════════════════
# EXPORTAR
# ═══════════════════════════════════════════════════════════════

write_csv(output_uplift, "outputs/output_uplift_scores.csv")

cat(sprintf("\n✅ Output exportado: outputs/output_uplift_scores.csv\n"))
cat(sprintf("   Clientes: %s\n", format(nrow(output_uplift), big.mark = ",")))
cat("   Conectado por customer_id al modelo estrella.\n\n")

cat("═══════════════════════════════════════════════════\n")
cat("  RESUMEN EJECUTIVO\n")
cat("═══════════════════════════════════════════════════\n")
cat(sprintf("  Persuadibles (invertir):     %d\n", sum(output_uplift$tipo_respuesta == "Persuadible")))
cat(sprintf("  Sure Things (no gastar):     %d\n", sum(output_uplift$tipo_respuesta == "Sure Thing")))
cat(sprintf("  Lost Causes (no gastar):     %d\n", sum(output_uplift$tipo_respuesta == "Lost Cause")))
cat(sprintf("  Sleeping Dogs (NO tocar):    %d\n", sum(output_uplift$tipo_respuesta == "Sleeping Dog")))
cat("═══════════════════════════════════════════════════\n")
