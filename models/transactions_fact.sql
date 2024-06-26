-- models/transactions_fact.sql

{{ config(        
        materialized="incremental",
        unique_key= "txn_key",
        on_schema_change='fail'
) }}

{% set table_exists_query = "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'dbt-facts' AND table_name = 'transactions_fact')" %}
{% set table_exists_result = run_query(table_exists_query) %}
{% set table_exists = table_exists_result.rows[0][0] if table_exists_result and table_exists_result.rows else False %}

WITH cost_table AS (
         SELECT 
             td.*,
             mc.amount                                      as meeza_processing_fees,
             0                                              AS corepay_fees,
             CAST(mc.amount AS DECIMAL(10, 2))              as total_fees_cost_before_vat,
             CAST(mc.vat * mc.amount AS DECIMAL(10, 2))     as total_fees_cost_after_vat,
             0                                              AS employee_discount,
             0                                              AS transaction_discount,
             0                                              AS discount,
             null                                           AS entity,
             null                                           AS protocol,
             0                                              as price,
             CASE WHEN lower(interchangeaction) = 'debit' THEN CAST(interchange_amount AS DECIMAL(10, 2)) + CAST(mc.amount AS DECIMAL(10, 2))
                 ELSE CAST(mc.amount AS DECIMAL(10, 2)) END as total_cost_before_vat,
             CASE WHEN lower(interchangeaction) = 'debit' THEN CAST(interchange_amount AS DECIMAL(10, 2)) + CAST(mc.vat * mc.amount AS DECIMAL(10, 2))
                 ELSE CAST(mc.amount AS DECIMAL(10, 2)) END as total_cost_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        JOIN {{source('dbt-dimensions', 'meeza_cost')}} mc on td.txntype = mc.transactiontype AND td.transactiondomain = mc.transactiondomain
        WHERE txntype in
                ('TransactionTypes_RECEIVE_P2P', 'TransactionTypes_ATM_CASH_OUT', 'TransactionTypes_ATM_CASH_IN',
                 'TransactionTypes_RECEIVE_AGENT_CASH_IN', 'TransactionTypes_RECEIVE_DEPOSIT',
                 'TransactionTypes_RECEIVE_EXPAYNET')
        AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')

        UNION

        SELECT 
            td.*,
            0                AS meeza_processing_fees,
            0                AS corepay_fees,
            0                AS total_fees_cost_before_vat,
            0                AS total_fees_cost_after_vat,
            0                AS employee_discount,
            0                AS transaction_discount,
            0                AS discount,
            null             AS entity,
            null             AS protocol,
            0                as price,
            (CASE WHEN transactiondomain = 'TransactionDomains_OFF_US' THEN service_fees / 2
              ELSE 0 END) as total_cost_before_vat,
            (CASE WHEN transactiondomain = 'TransactionDomains_OFF_US' THEN service_fees / 2
              ELSE 0 END) as total_cost_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        WHERE txntype in ('TransactionTypes_BILL_PAYMENT', 'TransactionTypes_TOP_UP')
        AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')
        
        UNION
        
        SELECT 
            td.*,
            0                                                                    AS meeza_processing_fees,
            COALESCE(bt.corepayfees::float, 0)                                   as corepay_fees,
            COALESCE(bt.corepayfees::float, 0)                                   as total_fees_cost_before_vat,
            COALESCE(bt.corepayfees::float, 0)                                   as total_fees_cost_after_vat,
            0                                                                    AS employee_discount,
            0                                                                    AS transaction_discount,
            COALESCE(bp.discount::float, 0)                                      as discount,
            tp.entity,
            tp.protocol,
            tp.price,
            COALESCE(bt.corepayfees::float, 0) + COALESCE(bp.discount::float, 0) as total_cost_before_vat,
            COALESCE(bt.corepayfees::float, 0) + COALESCE(bp.discount::float, 0) as total_cost_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        LEFT JOIN {{source('axis_sme', 'bankpaymenttransactions')}} bt ON td.txndetailsid = bt.originaltransactionid
        LEFT JOIN {{source('axis_sme', 'bankpayments')}} bp ON bt.bankpaymentid = bp.bankpaymentid
        LEFT JOIN {{source('dbt-dimensions', 'txn_proc_cost_table')}} tp ON td.txntype = tp.transactiontype
              AND td.transaction_createdat_utc2 between tp.createdat and COALESCE(tp.endedat, now())

        WHERE txntype = 'TransactionTypes_SEND_BANK_PAYMENT'
            AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')

        UNION
        
        SELECT 
            td.*,
            mc.amount                                                                    meeza_processing_fees,
            0                                                                         as corepay_fees,
            CAST(mc.amount AS DECIMAL(10, 2))                                         as total_fees_cost_before_vat,
            CAST(mc.vat * mc.amount AS DECIMAL(10, 2))                                as total_fees_cost_after_vat,
            coalesce(employeefeesdiscount::float, 0)                                  as employee_discount,
            coalesce(transactionfeesdiscount_aibyte_transform::float, 0)                               as transaction_discount,
            coalesce(employeefeesdiscount::float + transactionfeesdiscount_aibyte_transform::float, 0) as discount,
            NULL                                                                      as entity,
            NULL                                                                      as protocol,
            NULL                                                                      as price,
            coalesce(employeefeesdiscount::float, 0) + coalesce(transactionfeesdiscount_aibyte_transform::float, 0) +
            CAST(mc.amount AS DECIMAL(10, 2))                                         as total_cost_before_vat,
            coalesce(employeefeesdiscount::float, 0) + coalesce(transactionfeesdiscount_aibyte_transform::float, 0) +
            CAST(mc.vat * mc.amount AS DECIMAL(10, 2))                                as total_cost_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        LEFT JOIN {{source('dbt-dimensions', 'meeza_cost')}} mc ON td.txntype = mc.transactiontype AND td.transactiondomain = mc.transactiondomain
        LEFT JOIN {{source('axis_sme', 'disbursementtransactions')}} dt ON td.transactionreference = dt.wallettransactionreference
        WHERE txntype = 'TransactionTypes_SEND_SME_DEPOSIT'
            AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')
),


revenue_table AS (
        SELECT
            td.*,
            0 AS employee_vat,
            0 AS transaction_vat,
            coalesce(bp.vat::float, 0) as bank_vat,
            coalesce(bp.vat::float, 0) as total_vat,
            0 AS employee_fees,
            0 AS transaction_fees,
            coalesce(bt.axisfees_aibyte_transform::float, 0) as bank_fees,
            coalesce(bt.axisfees_aibyte_transform::float, 0) as total_revenue_before_vat,
            coalesce(bt.axisfees_aibyte_transform::float, 0) * coalesce(bp.vat::float, 1) as total_revenue_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        LEFT JOIN {{source('axis_sme', '_airbyte_raw_bankpaymenttransactions')}} bt ON td.txndetailsid = bt.originaltransactionid
        LEFT JOIN {{source('axis_sme', '_airbyte_raw_bankpayments')}} bp ON bt.bankpaymentid = bp.bankpaymentid
        WHERE txntype = 'TransactionTypes_SEND_BANK_PAYMENT' AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE') AND isreversedflag = false

        UNION

        SELECT
            td.*,
            coalesce(employeefeesvat_aibyte_transform::float, 0) as employee_vat,
            coalesce(transactionfeesvat_aibyte_transform::float, 0) as transaction_vat,
            0 AS bank_vat,
            coalesce(employeefeesvat_aibyte_transform::float, 0) + coalesce(transactionfeesvat_aibyte_transform::float, 0) as total_vat,
            coalesce(employeefees::float, 0) as employee_fees,
            coalesce(fees_aibyte_transform::float, 0) as transaction_fees,
            0 AS bank_fees,
            coalesce(employeefees::float, 0) + coalesce(fees_aibyte_transform::float, 0) as total_revenue_before_vat,
            (coalesce(employeefeesvat_aibyte_transform::float, 1) + coalesce(transactionfeesvat_aibyte_transform::float, 1)) * (coalesce(employeefees::float, 0) + coalesce(fees_aibyte_transform::float, 0)) as total_revenue_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        LEFT JOIN {{source('axis_sme', '_airbyte_raw_disbursementtransactions')}} dt ON td.transactionreference = dt.wallettransactionreference
        WHERE txntype = 'TransactionTypes_SEND_SME_DEPOSIT'
                AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')

        UNION

        SELECT
            td.*,
            coalesce(employeefeesvat_aibyte_transform::float, 0) as employee_vat,
            coalesce(transactionfeesvat_aibyte_transform::float, 0) as transaction_vat,
            0 AS bank_vat,
            coalesce(employeefeesvat_aibyte_transform::float, 0) + coalesce(transactionfeesvat_aibyte_transform::float, 0) as total_vat,
            employeefees::float as employee_fees,
            fees_aibyte_transform::float as transaction_fees,
            0 AS bank_fees,
            coalesce(employeefees::float, 0) + coalesce(fees_aibyte_transform::float, 0) as total_revenue_before_vat,
            (coalesce(employeefeesvat_aibyte_transform::float, 1) + coalesce(transactionfeesvat_aibyte_transform::float, 1)) * (coalesce(employeefees::float, 0) + coalesce(fees_aibyte_transform::float, 0)) as total_revenue_after_vat


        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        LEFT JOIN {{source('axis_sme', '_airbyte_raw_disbursementtransactions')}} dt ON td.transactionreference = dt.wallettransactionreference
        WHERE txntype = 'TransactionTypes_SEND_SME_PAYROLL_DEPOSIT'
                AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')

        UNION

        SELECT
            td.*,
            0 AS employee_vat,
            0 AS transaction_vat,
            0 AS bank_vat,
            0 AS total_vat,
            0 AS employee_fees,
            0 AS transaction_fees,
            0 AS bank_fees,
            coalesce(td.amount::float, 0) AS total_revenue_before_vat,
            coalesce(td.amount::float, 0) AS total_revenue_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        WHERE txntype = 'TransactionTypes_SEND_SME_SUBSCRIPTION_PAYMENT'
          AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')
          AND isreversedflag = false

        UNION

        SELECT
            td.*,
            0 AS employee_vat,
            0 AS transaction_vat,
            0 AS bank_vat,
            0 AS total_vat,
            0 AS employee_fees,
            0 AS transaction_fees,
            0 AS bank_fees,
            (CASE WHEN lower(interchangeaction) = 'credit' AND transactiondomain = 'TransactionDomains_OFF_US'
                THEN interchange_amount ELSE 0  END) as total_revenue_before_vat,
            (CASE WHEN lower(interchangeaction) = 'credit' AND transactiondomain = 'TransactionDomains_OFF_US'
                THEN interchange_amount ELSE 0  END) as total_revenue_ater_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        WHERE txntype = 'TransactionTypes_SEND_P2P'
            AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')

        UNION

        SELECT
            td.*,
            0 AS employee_vat,
            0 AS transaction_vat,
            0 AS bank_vat,
            0 AS total_vat,
            0 AS employee_fees,
            0 AS transaction_fees,
            0 AS bank_fees,
            (CASE WHEN lower(interchangeaction) = 'credit' AND hasservicefees = true
                THEN interchange_amount + (service_fees::float) ELSE coalesce(service_fees::float, 0) END) as total_revenue_before_vat,
            (CASE WHEN lower(interchangeaction) = 'credit' AND hasservicefees = true
                THEN interchange_amount + (service_fees::float) ELSE coalesce(service_fees::float, 0) END) as total_revenue_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        WHERE txntype in ('TransactionTypes_ATM_CASH_OUT', 'TransactionTypes_ATM_CASH_IN', 'TransactionTypes_ATM_CASH_OUT_REVERSAL', 'TransactionTypes_ATM_CASH_IN_REVERSAL')
            AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')

        UNION

        SELECT
            td.*,
            0 AS employee_vat,
            0 AS transaction_vat,
            0 AS bank_vat,
            0 AS total_vat,
            0 AS employee_fees,
            0 AS transaction_fees,
            0 AS bank_fees,
            (service_fees::float) as total_revenue_before_vat,
            (service_fees::float) as total_revenue_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        WHERE txntype in ('TransactionTypes_BILL_PAYMENT', 'TransactionTypes_TOP_UP')
            AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')

        UNION

        SELECT
            td.*,
            0 AS employee_vat,
            0 AS transaction_vat,
            0 AS bank_vat,
            0 AS total_vat,
            0 AS employee_fees,
            0 AS transaction_fees,
            0 AS bank_fees,
            td.amount as total_revenue_before_vat,
            td.amount as total_revenue_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        WHERE txntype = 'TransactionTypes_CREATE_VCN_FEES'
            AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')

        UNION

        SELECT
            td.*,
            0 AS employee_vat,
            0 AS transaction_vat,
            0 AS bank_vat,
            0 AS total_vat,
            0 AS employee_fees,
            0 AS transaction_fees,
            0 AS bank_fees,
            CASE WHEN hasservicefees = true THEN td.service_fees ELSE 0 END as total_revenue_before_vat,
            CASE WHEN hasservicefees = true THEN td.service_fees ELSE 0 END as total_revenue_after_vat

        FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
        WHERE txntype = 'TransactionTypes_SEND_REDEEM_SME_INADVANCE_DEPOSIT'
            AND transactionstatus IN ('TransactionStatus_POSTED', 'TransactionStatus_PENDING_ADVICE')
)
SELECT
    md5(random()::text || '-' || COALESCE(td.id, '') || '-' || COALESCE(wd.id, '') || '-' || COALESCE(dd.date_id::text, '') || '-' || now()::text) AS id,
    td.id AS txn_key,
    dd.date_id AS date_key,
    tid.time_id AS time_key,
    wd.id AS wallet_key,
    cd.id AS client_key,
    ed.id AS employee_key,  
    td.amount,
    ROUND(coalesce(ct.total_cost_before_vat, 0)::numeric, 2) as total_cost_before_vat,
    ROUND(coalesce(rt.total_revenue_before_vat, 0)::numeric, 2) as total_revenue_before_vat,
    ROUND(coalesce(ct.total_cost_after_vat, 0)::numeric, 2) as total_cost_after_vat,
    ROUND(coalesce(rt.total_revenue_after_vat, 0)::numeric, 2) as total_revenue_after_vat,
    ROUND(SUM(COALESCE(rt.total_revenue_before_vat, 0) - COALESCE(ct.total_cost_before_vat, 0))::numeric, 2) as total_profit,
    (now()::timestamptz AT TIME ZONE 'UTC' + INTERVAL '2 hours') as loaddate,
    CASE
        WHEN cd.id IS NOT NULL AND ed.id IS NOT NULL THEN true
        ELSE false
    END AS is_employee


FROM {{source('dbt-dimensions', 'transactions_dimension')}} td
LEFT JOIN {{source('dbt-dimensions', 'wallets_dimension')}} wd ON td.walletdetailsid = wd.walletid
LEFT JOIN {{source('dbt-dimensions', 'employees_dimension')}} ed ON (wd.walletnumber = ed.employee_mobile AND
            (td.transaction_createdat_utc2 between employee_createdat_utc2 and employee_deletedat_utc2))
LEFT JOIN {{source('dbt-dimensions', 'clients_dimension')}} cd ON td.clientdetails ->> 'clientId' = cd.clientid
LEFT JOIN {{source('dbt-dimensions', 'date_dimension')}} dd ON DATE(td.transaction_modifiedat_utc2) = dd.full_date
LEFT JOIN {{source('dbt-dimensions', 'time_dimension')}} tid ON TO_CHAR(td.transaction_modifiedat_utc2, 'HH24:MI:00') = TO_CHAR(tid.full_time, 'HH24:MI:SS')
LEFT join cost_table ct on td.txndetailsid = ct.txndetailsid
LEFT join revenue_table rt on td.txndetailsid = rt.txndetailsid

{% if is_incremental() and table_exists %}
    WHERE td.loaddate > COALESCE((SELECT max(loaddate::timestamptz) FROM {{ source('dbt-facts', 'transactions_fact') }}), '1900-01-01'::timestamp)
{% endif %}

GROUP BY td.amount,
         ct.total_cost_before_vat, rt.total_revenue_before_vat, ct.total_cost_after_vat, rt.total_revenue_after_vat,
         dd.date_id, tid.time_id,  ed.id, wd.id, cd.id, td.id
