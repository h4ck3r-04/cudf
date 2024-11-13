# Copyright (c) 2024, NVIDIA CORPORATION.
from pylibcudf.column import Column
from pylibcudf.expressions import Expression
from pylibcudf.gpumemoryview import gpumemoryview
from pylibcudf.table import Table
from pylibcudf.types import DataType

def nans_to_nulls(input: Column) -> tuple[gpumemoryview, int]: ...
def compute_column(input: Table, expr: Expression) -> Column: ...
def bools_to_mask(input: Column) -> tuple[gpumemoryview, int]: ...
def mask_to_bools(bitmask: int, begin_bit: int, end_bit: int) -> Column: ...
def transform(
    input: Column, unary_udf: str, output_type: DataType, is_ptx: bool
) -> Column: ...
def encode(input: Table) -> tuple[Table, Column]: ...
def one_hot_encode(input: Column, categories: Column) -> Table: ...