// The idea of this file is to have functions that
// transform the expressions from the Elixir side
// to the Rust side. Each function receives a basic type
// or an expression and returns an expression that is
// wrapped in an Elixir struct.

use chrono::{NaiveDate, NaiveDateTime};
use polars::prelude::{col, when, DataFrame, IntoLazy, LiteralValue, SortOptions};
use polars::prelude::{Expr, Literal};

use crate::datatypes::{ExDate, ExDateTime};
use crate::series::{cast_str_to_dtype, rolling_opts};
use crate::{ExDataFrame, ExExpr};

#[rustler::nif]
pub fn expr_integer(number: i64) -> ExExpr {
    let expr = number.lit();
    ExExpr::new(expr)
}

#[rustler::nif]
pub fn expr_float(number: f64) -> ExExpr {
    let expr = number.lit();
    ExExpr::new(expr)
}

#[rustler::nif]
pub fn expr_string(string: String) -> ExExpr {
    let expr = string.lit();
    ExExpr::new(expr)
}

#[rustler::nif]
pub fn expr_boolean(boolean: bool) -> ExExpr {
    let expr = boolean.lit();
    ExExpr::new(expr)
}

#[rustler::nif]
pub fn expr_date(date: ExDate) -> ExExpr {
    let naive_date = NaiveDate::from(date);
    let expr = naive_date.lit();
    ExExpr::new(expr)
}

#[rustler::nif]
pub fn expr_datetime(datetime: ExDateTime) -> ExExpr {
    let naive_datetime = NaiveDateTime::from(datetime);
    let expr = naive_datetime.lit();
    ExExpr::new(expr)
}

#[rustler::nif]
pub fn expr_cast(data: ExExpr, to_dtype: &str) -> ExExpr {
    let expr: Expr = data.resource.0.clone();
    let to_dtype = cast_str_to_dtype(to_dtype).expect("dtype is not valid");

    ExExpr::new(expr.cast(to_dtype))
}

#[rustler::nif]
pub fn expr_column(name: &str) -> ExExpr {
    let expr = col(name);
    ExExpr::new(expr)
}

#[rustler::nif]
pub fn expr_eq(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.eq(right_expr))
}

#[rustler::nif]
pub fn expr_neq(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.neq(right_expr))
}

#[rustler::nif]
pub fn expr_gt(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.gt(right_expr))
}

#[rustler::nif]
pub fn expr_gt_eq(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.gt_eq(right_expr))
}

#[rustler::nif]
pub fn expr_lt(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.lt(right_expr))
}

#[rustler::nif]
pub fn expr_lt_eq(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.lt_eq(right_expr))
}

#[rustler::nif]
pub fn expr_binary_and(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.and(right_expr))
}

#[rustler::nif]
pub fn expr_binary_or(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.or(right_expr))
}

#[rustler::nif]
pub fn expr_is_nil(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.is_null())
}

#[rustler::nif]
pub fn expr_is_not_nil(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.is_not_null())
}

#[rustler::nif]
pub fn expr_all_equal(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.eq(right_expr).all())
}

#[rustler::nif]
pub fn expr_slice(expr: ExExpr, offset: i64, length: u32) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.slice(offset, length))
}

#[rustler::nif]
pub fn expr_head(expr: ExExpr, length: usize) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.head(Some(length)))
}

#[rustler::nif]
pub fn expr_tail(expr: ExExpr, length: usize) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.tail(Some(length)))
}

#[rustler::nif]
pub fn expr_peaks(data: ExExpr, min_or_max: &str) -> ExExpr {
    let expr: Expr = data.resource.0.clone();
    let type_expr = if min_or_max == "min" {
        expr.min()
    } else {
        expr.max()
    };

    ExExpr::new(data.resource.0.clone().eq(type_expr))
}

#[rustler::nif]
pub fn expr_fill_missing(data: ExExpr, strategy: &str) -> ExExpr {
    let orig_expr = &data.resource.0;
    let expr: Expr = orig_expr.clone();
    let result_expr = match strategy {
        "backward" => expr.backward_fill(None),
        "forward" => expr.forward_fill(None),
        "min" => expr.fill_null(orig_expr.clone().min()),
        "max" => expr.fill_null(orig_expr.clone().max()),
        "mean" => expr.fill_null(orig_expr.clone().mean()),
        _other => panic!("unknown strategy"),
    };
    ExExpr::new(result_expr)
}

#[rustler::nif]
pub fn expr_fill_missing_with_value(data: ExExpr, value: ExExpr) -> ExExpr {
    let expr: Expr = data.resource.0.clone();
    let value: Expr = value.resource.0.clone();
    ExExpr::new(expr.fill_null(value))
}

#[rustler::nif]
pub fn expr_add(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr + right_expr)
}

#[rustler::nif]
pub fn expr_subtract(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr - right_expr)
}

#[rustler::nif]
pub fn expr_divide(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr / right_expr)
}

#[rustler::nif]
pub fn expr_quotient(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    let quotient = left_expr
        / when(right_expr.clone().eq(0))
            .then(Expr::Literal(LiteralValue::Null))
            .otherwise(right_expr);

    ExExpr::new(quotient)
}

#[rustler::nif]
pub fn expr_remainder(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    let quotient = left_expr.clone()
        / when(right_expr.clone().eq(0))
            .then(Expr::Literal(LiteralValue::Null))
            .otherwise(right_expr.clone());

    let mult = right_expr * quotient;
    let result = left_expr - mult;

    ExExpr::new(result)
}

#[rustler::nif]
pub fn expr_multiply(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr * right_expr)
}

#[rustler::nif]
pub fn expr_pow(left: ExExpr, right: ExExpr) -> ExExpr {
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    ExExpr::new(left_expr.pow(right_expr))
}

#[rustler::nif]
pub fn expr_sum(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.sum())
}

#[rustler::nif]
pub fn expr_min(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.min())
}

#[rustler::nif]
pub fn expr_max(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.max())
}

#[rustler::nif]
pub fn expr_mean(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.mean())
}

#[rustler::nif]
pub fn expr_median(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.median())
}

#[rustler::nif]
pub fn expr_var(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.var(1))
}

#[rustler::nif]
pub fn expr_std(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.std(1))
}

#[rustler::nif]
pub fn expr_quantile(expr: ExExpr, quantile: f64) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();
    // TODO: consider accepting strategy in the future.
    let strategy = crate::parse_quantile_interpol_options("nearest");

    ExExpr::new(expr.quantile(quantile, strategy))
}

#[rustler::nif]
pub fn expr_alias(expr: ExExpr, name: &str) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.alias(name))
}

#[rustler::nif]
pub fn expr_count(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.count())
}

#[rustler::nif]
pub fn expr_n_distinct(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.n_unique())
}

#[rustler::nif]
pub fn expr_first(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.first())
}

#[rustler::nif]
pub fn expr_last(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.last())
}

#[rustler::nif]
pub fn expr_coalesce(left: ExExpr, right: ExExpr) -> ExExpr {
    let predicate: Expr = left.resource.0.clone().is_not_null();
    let left_expr: Expr = left.resource.0.clone();
    let right_expr: Expr = right.resource.0.clone();

    let condition = when(predicate).then(left_expr).otherwise(right_expr);

    ExExpr::new(condition)
}

// window functions
macro_rules! init_window_expr_fun {
    ($name:ident, $fun:ident) => {
        #[rustler::nif(schedule = "DirtyCpu")]
        pub fn $name(
            data: ExExpr,
            window_size: usize,
            weights: Option<Vec<f64>>,
            min_periods: Option<usize>,
            center: bool,
        ) -> ExExpr {
            let expr: Expr = data.resource.0.clone();
            let opts = rolling_opts(window_size, weights, min_periods, center);
            ExExpr::new(expr.$fun(opts))
        }
    };
}

init_window_expr_fun!(expr_window_max, rolling_max);
init_window_expr_fun!(expr_window_min, rolling_min);
init_window_expr_fun!(expr_window_sum, rolling_sum);
init_window_expr_fun!(expr_window_mean, rolling_mean);

#[rustler::nif]
pub fn expr_cumulative_min(data: ExExpr, reverse: bool) -> ExExpr {
    let expr: Expr = data.resource.0.clone();
    ExExpr::new(expr.cummin(reverse))
}

#[rustler::nif]
pub fn expr_cumulative_max(data: ExExpr, reverse: bool) -> ExExpr {
    let expr: Expr = data.resource.0.clone();
    ExExpr::new(expr.cummax(reverse))
}

#[rustler::nif]
pub fn expr_cumulative_sum(data: ExExpr, reverse: bool) -> ExExpr {
    let expr: Expr = data.resource.0.clone();
    ExExpr::new(expr.cumsum(reverse))
}

#[rustler::nif]
pub fn expr_reverse(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.reverse())
}

#[rustler::nif]
pub fn expr_sort(expr: ExExpr, reverse: bool) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.sort(reverse))
}

#[rustler::nif]
pub fn expr_argsort(expr: ExExpr, reverse: bool) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();
    // TODO: check if we want nulls last
    let opts = SortOptions {
        descending: reverse,
        nulls_last: false,
    };

    ExExpr::new(expr.arg_sort(opts))
}

#[rustler::nif]
pub fn expr_distinct(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.unique_stable())
}

#[rustler::nif]
pub fn expr_unordered_distinct(expr: ExExpr) -> ExExpr {
    let expr: Expr = expr.resource.0.clone();

    ExExpr::new(expr.unique())
}

#[rustler::nif]
pub fn expr_describe_filter_plan(data: ExDataFrame, expr: ExExpr) -> String {
    let df: DataFrame = data.resource.0.clone();
    let expressions: Expr = expr.resource.0.clone();
    df.lazy().filter(expressions).describe_plan()
}
