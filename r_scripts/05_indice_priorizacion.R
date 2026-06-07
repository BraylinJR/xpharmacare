# ═══════════════════════════════════════════════════════════════
# XFarmaCare — Índice de Priorización (Matriz de Valor)
# ═══════════════════════════════════════════════════════════════
#
# Este script calcula un score unificado para cada cliente que
# responde la pregunta: "¿A quién salvamos primero?"
#
# Componentes del índice (ponderados):
#   1. Margen neto de sus compras (25%)
#   2. Ingreso bruto histórico (20%)
#   3. Frecuencia de compra (15%)
#   4. Programa de lealtad (10%)
#   5. Tasa de adherencia terapéutica (30%) ← Métrica estrella
#
# Input:  outputs/dataset_analitico_clientes.csv
# Output: outputs/output_indice_priorizacion.csv
# ═══════════════════════════════════════════════════════════════

# --- Cargar librerías ---
library(dplyr)
library(readr)
library(ggplot2)
library(scales)

cat("═══════════════════════════════════════════════════\n")
cat("  XFarmaCare — Cálculo del Índice de Priorización\n")
cat("═══════════════════════════════════════════════════\n\n")

# --- Rutas ---
INPUT_FILE  <- "outputs/dataset_analitico_clientes.csv"
OUTPUT_FILE <- "outputs/output_indice_priorizacion.csv"
TRANSACCIONES_FILE <- "data/fact_transacciones.csv"
PRODUCTOS_FILE <- "data/dim_productos.csv"

# --- Cargar datos ---
df <- read_csv(INPUT_FILE, show_col_types = FALSE)
txn <- read_csv(TRANSACCIONES_FILE, show_col_types = FALSE)
prod <- read_csv(PRODUCTOS_FILE, show_col_types = FALSE)

cat(sprintf("Clientes cargados: %s\n", format(nrow(df), big.mark = ",")))
cat(sprintf("Transacciones: %s\n", format(nrow(txn), big.mark = ",")))

# ═══════════════════════════════════════════════════════════════
# COMPONENTE 1: Margen Neto (25%)
# ═══════════════════════════════════════════════════════════════
# Calculamos el margen real que cada cliente genera, no solo el ingreso.

cat("\n[1/5] Calculando margen neto por cliente...\n")

# Unir transacciones con productos para obtener el costo
txn_margen <- txn %>%
  left_join(prod %>% select(product_id, costo_unitario_dop, margen_porcentaje),
            by = "product_id") %>%
  mutate(
    costo_total = costo_unitario_dop * cantidad,
    margen_bruto = total_venta_dop - costo_total
  )

margen_cliente <- txn_margen %>%
  group_by(customer_id) %>%
  summarise(
    margen_neto_total = sum(margen_bruto, na.rm = TRUE),
    margen_promedio_txn = mean(margen_bruto, na.rm = TRUE),
    .groups = "drop"
  )

cat(sprintf("  Margen neto promedio por cliente: RD$ %s\n",
            format(round(mean(margen_cliente$margen_neto_total)), big.mark = ",")))

# ═══════════════════════════════════════════════════════════════
# COMPONENTE 2: Ingreso Bruto Histórico (20%)
# ═══════════════════════════════════════════════════════════════

cat("[2/5] Calculando ingreso bruto histórico...\n")

# Ya lo tenemos en el dataset analítico como total_gastado_dop
# Lo normalizamos de 0 a 100

# ═══════════════════════════════════════════════════════════════
# COMPONENTE 3: Frecuencia de Compra (15%)
# ═══════════════════════════════════════════════════════════════

cat("[3/5] Calculando score de frecuencia...\n")

# Ya tenemos frecuencia_mensual en el dataset

# ═══════════════════════════════════════════════════════════════
# COMPONENTE 4: Programa de Lealtad (10%)
# ═══════════════════════════════════════════════════════════════

cat("[4/5] Calculando score de lealtad...\n")

# Asignar puntos por nivel de lealtad
score_lealtad <- data.frame(
  nivel_lealtad = c("Platino", "Oro", "Plata", "Bronce", "Sin programa"),
  score_programa = c(100, 75, 50, 25, 0)
)

# ═══════════════════════════════════════════════════════════════
# COMPONENTE 5: Adherencia Terapéutica (30%) ← MÉTRICA ESTRELLA
# ═══════════════════════════════════════════════════════════════

cat("[5/5] Calculando score de adherencia (métrica estrella)...\n")

# Para crónicos: la adherencia es el multiplicador de CLV.
# Un crónico adherente tiene un valor de vida predecible y alto.
# Para no crónicos: este componente se neutraliza (score = 50).

# ═══════════════════════════════════════════════════════════════
# CÁLCULO DEL ÍNDICE UNIFICADO
# ═══════════════════════════════════════════════════════════════

cat("\nCalculando índice unificado...\n")

# Función para normalizar de 0 a 100 (min-max scaling)
normalizar <- function(x) {
  rng <- range(x, na.rm = TRUE)
  if (rng[2] == rng[1]) return(rep(50, length(x)))
  return(round((x - rng[1]) / (rng[2] - rng[1]) * 100, 2))
}

# Unir margen al dataset principal
df_idx <- df %>%
  left_join(margen_cliente, by = "customer_id") %>%
  left_join(score_lealtad, by = "nivel_lealtad") %>%
  mutate(
    # Normalizar cada componente de 0 a 100
    score_margen     = normalizar(ifelse(is.na(margen_neto_total), 0, margen_neto_total)),
    score_ingreso    = normalizar(ifelse(is.na(total_gastado_dop), 0, total_gastado_dop)),
    score_frecuencia = normalizar(ifelse(is.na(frecuencia_mensual), 0, frecuencia_mensual)),
    score_programa   = ifelse(is.na(score_programa), 0, score_programa),

    # Adherencia: para crónicos usar su tasa real, para no crónicos = 50
    score_adherencia = ifelse(
      es_cronico == TRUE,
      normalizar(ifelse(is.na(tasa_adherencia_promedio), 0.5, tasa_adherencia_promedio)),
      50  # Neutral para no crónicos
    ),

    # === ÍNDICE PONDERADO ===
    indice_priorizacion = round(
      score_margen     * 0.25 +
      score_ingreso    * 0.20 +
      score_frecuencia * 0.15 +
      score_programa   * 0.10 +
      score_adherencia * 0.30,
      2
    )
  )

# Categorías de valor
df_idx <- df_idx %>%
  mutate(
    categoria_valor = case_when(
      indice_priorizacion >= 75 ~ "Platino (Top)",
      indice_priorizacion >= 55 ~ "Alto Valor",
      indice_priorizacion >= 35 ~ "Valor Medio",
      indice_priorizacion >= 15 ~ "Valor Bajo",
      TRUE                      ~ "En Riesgo de Pérdida"
    )
  )

# ═══════════════════════════════════════════════════════════════
# RESULTADOS
# ═══════════════════════════════════════════════════════════════

cat("\n═══════════════════════════════════════════════════\n")
cat("  RESULTADOS DEL ÍNDICE DE PRIORIZACIÓN\n")
cat("═══════════════════════════════════════════════════\n\n")

resumen <- df_idx %>%
  group_by(categoria_valor) %>%
  summarise(
    n_clientes = n(),
    indice_promedio = round(mean(indice_priorizacion), 1),
    margen_promedio = round(mean(margen_neto_total, na.rm = TRUE)),
    pct_cronicos = round(mean(es_cronico == TRUE) * 100, 1),
    .groups = "drop"
  ) %>%
  arrange(desc(indice_promedio))

print(resumen)

cat(sprintf("\nÍndice promedio general: %.1f\n", mean(df_idx$indice_priorizacion)))
cat(sprintf("Clientes Platino (Top): %d (%.1f%%)\n",
            sum(df_idx$categoria_valor == "Platino (Top)"),
            mean(df_idx$categoria_valor == "Platino (Top)") * 100))

# ═══════════════════════════════════════════════════════════════
# CLV SIMPLIFICADO PARA CRÓNICOS
# ═══════════════════════════════════════════════════════════════

cat("\nCalculando CLV simplificado para pacientes crónicos...\n")

# CLV = Margen mensual promedio × Tasa de retención × Horizonte (meses)
# Para crónicos, la adherencia es proxy de la tasa de retención

cronicos_idx <- df_idx %>%
  filter(es_cronico == TRUE) %>%
  mutate(
    margen_mensual = ifelse(is.na(margen_neto_total) | antiguedad_dias == 0,
                            0,
                            margen_neto_total / pmax(antiguedad_dias / 30, 1)),
    tasa_retencion_mensual = pmin(tasa_adherencia_promedio, 0.98),
    # CLV con horizonte de 24 meses y tasa de descuento del 1% mensual
    clv_24m = round(margen_mensual * (tasa_retencion_mensual / (1 - tasa_retencion_mensual + 0.01)) *
                     (1 - ((tasa_retencion_mensual / 1.01)^24)), 0)
  )

cat(sprintf("  CLV promedio 24 meses (crónicos): RD$ %s\n",
            format(round(mean(cronicos_idx$clv_24m, na.rm = TRUE)), big.mark = ",")))
cat(sprintf("  CLV mediana: RD$ %s\n",
            format(round(median(cronicos_idx$clv_24m, na.rm = TRUE)), big.mark = ",")))

# Unir CLV al dataset
df_idx <- df_idx %>%
  left_join(cronicos_idx %>% select(customer_id, clv_24m), by = "customer_id") %>%
  mutate(clv_24m = ifelse(is.na(clv_24m), 0, clv_24m))

# ═══════════════════════════════════════════════════════════════
# EXPORTAR
# ═══════════════════════════════════════════════════════════════

output <- df_idx %>%
  select(
    customer_id,
    score_margen, score_ingreso, score_frecuencia,
    score_programa, score_adherencia,
    indice_priorizacion, categoria_valor,
    clv_24m
  ) %>%
  mutate(fecha_calculo = Sys.Date())

write_csv(output, OUTPUT_FILE)

cat(sprintf("\n✅ Índice exportado: %s\n", OUTPUT_FILE))
cat(sprintf("   Clientes: %s\n", format(nrow(output), big.mark = ",")))
cat(sprintf("   Columnas: %d\n", ncol(output)))
cat("\nComponentes del índice conectados por customer_id al modelo estrella.\n")
