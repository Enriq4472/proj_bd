-- limpeza de tabelas

DROP VIEW IF EXISTS v_active_services;
DROP TRIGGER IF EXISTS trg_update_order_value ON ordem_peca;
DROP FUNCTION IF EXISTS fn_update_total_order;

DROP TABLE IF EXISTS ordem_peca CASCADE;
DROP TABLE IF EXISTS fornecedor_peca CASCADE;
DROP TABLE IF EXISTS peca CASCADE;
DROP TABLE IF EXISTS fornecedor CASCADE;
DROP TABLE IF EXISTS ordens_servico CASCADE;
DROP TABLE IF EXISTS chassis CASCADE;
DROP TABLE IF EXISTS cliente CASCADE;
DROP TABLE IF EXISTS modelo_carro CASCADE;
DROP TABLE IF EXISTS status CASCADE;
DROP TABLE IF EXISTS prioridade CASCADE;
DROP TABLE IF EXISTS tipo_peca CASCADE;
DROP TABLE IF EXISTS marca CASCADE;

-- Criando tabelas

CREATE TABLE marca (
    id_marca SERIAL PRIMARY KEY,
    nome_marca VARCHAR(100),
    pais_origem VARCHAR(100)
);

CREATE TABLE tipo_peca (
    id_tipo_peca SERIAL PRIMARY KEY,
    descricao VARCHAR(100)
);

CREATE TABLE prioridade (
    id_prioridade SERIAL PRIMARY KEY,
    descricao VARCHAR(50)
);

CREATE TABLE status (
    id_status SERIAL PRIMARY KEY,
    descricao VARCHAR(50)
);

CREATE TABLE cliente (
    id_cliente SERIAL PRIMARY KEY,
    nome_cliente VARCHAR(150),
    celular_cliente VARCHAR(20)
);

CREATE TABLE fornecedor (
    id_fornecedor SERIAL PRIMARY KEY,
    nome VARCHAR(150),
    cidade VARCHAR(100),
    telefone VARCHAR(20),
    site VARCHAR(150)
);

CREATE TABLE modelo_carro (
    id_modelo SERIAL PRIMARY KEY,
    nome_modelo VARCHAR(100),
    ano_lancamento INT,
    id_marca INT REFERENCES marca(id_marca)
);

CREATE TABLE peca (
    id_peca SERIAL PRIMARY KEY,
    nome_peca VARCHAR(100),
    preco DECIMAL(10,2),
    id_marca INT REFERENCES marca(id_marca),
    id_tipo_peca INT REFERENCES tipo_peca(id_tipo_peca)
);

CREATE TABLE chassis (
    id_chassis SERIAL PRIMARY KEY,
    ano_compra INT,
    id_modelo INT REFERENCES modelo_carro(id_modelo),
    id_cliente INT REFERENCES cliente(id_cliente)
);

CREATE TABLE ordens_servico (
    id_ordem SERIAL PRIMARY KEY,
    data_abertura TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    data_fechamento TIMESTAMP,
    descricao TEXT,
    valor_total DECIMAL(10,2) DEFAULT 0,
    id_cliente INT REFERENCES cliente(id_cliente),
    id_chassis INT REFERENCES chassis(id_chassis),
    id_prioridade INT REFERENCES prioridade(id_prioridade),
    id_status INT REFERENCES status(id_status)
);

CREATE TABLE fornecedor_peca (
    id_fornecedor INT REFERENCES fornecedor(id_fornecedor),
    id_peca INT REFERENCES peca(id_peca),
    PRIMARY KEY (id_fornecedor, id_peca)
);

CREATE TABLE ordem_peca (
    id_ordem INT REFERENCES ordens_servico(id_ordem),
    id_peca INT REFERENCES peca(id_peca),
    quantidade INT,
    valor_unitario DECIMAL(10,2),
    PRIMARY KEY (id_ordem, id_peca)
);


-- criando views

-- visualizando servicos ativos
CREATE VIEW v_active_services AS
SELECT 
    os.id_ordem,
    c.nome_cliente,
    mc.nome_modelo,
    p.descricao AS prioridade_label,
    s.descricao AS status_label,
    os.data_abertura
FROM ordens_servico os
JOIN cliente c ON os.id_cliente = c.id_cliente
JOIN chassis ch ON os.id_chassis = ch.id_chassis
JOIN modelo_carro mc ON ch.id_modelo = mc.id_modelo
JOIN prioridade p ON os.id_prioridade = p.id_prioridade
JOIN status s ON os.id_status = s.id_status;


-- criando triggers

-- atualiza o valor total da os automaticamente
CREATE OR REPLACE FUNCTION fn_update_total_order()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE ordens_servico
    SET valor_total = (
        SELECT COALESCE(SUM(quantidade * valor_unitario), 0)
        FROM ordem_peca
        WHERE id_ordem = NEW.id_ordem
    )
    WHERE id_ordem = NEW.id_ordem;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_order_value
AFTER INSERT OR UPDATE OR DELETE ON ordem_peca
FOR EACH ROW
EXECUTE FUNCTION fn_update_total_order();


-- Nao permite data_fechamento antes de data_abertura

CREATE OR REPLACE FUNCTION fn_check_dates()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.data_fechamento < NEW.data_abertura THEN
        RAISE EXCEPTION 'A data de fechamento nao pode ser anterior a data de abertura';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_dates
BEFORE UPDATE ON ordens_servico
FOR EACH ROW
EXECUTE FUNCTION fn_check_dates();

-- configura a data de fechamento de forma automatica quando o status for  "finalizado"

CREATE OR REPLACE FUNCTION fn_set_closing_date()
RETURNS TRIGGER AS $$
BEGIN
    -- Assumes ID 3 is 'Finalizado' based on our insert
    IF NEW.id_status = 3 AND OLD.id_status != 3 THEN
        NEW.data_fechamento = CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_auto_close
BEFORE UPDATE ON ordens_servico
FOR EACH ROW
EXECUTE FUNCTION fn_set_closing_date();

-- Procura o preço da peca na tabela preco e coloca no ordem_peca

CREATE OR REPLACE FUNCTION fn_fetch_part_price()
RETURNS TRIGGER AS $$
BEGIN
    -- pegando valor somente caso nao seja preenchido
    IF NEW.valor_unitario IS NULL OR NEW.valor_unitario = 0 THEN
        SELECT preco INTO NEW.valor_unitario 
        FROM peca 
        WHERE id_peca = NEW.id_peca;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_fetch_price
BEFORE INSERT ON ordem_peca
FOR EACH ROW
EXECUTE FUNCTION fn_fetch_part_price();


-- View geral para verificar o que ocorre com um carro especifico quando chamado

CREATE OR REPLACE VIEW v_complete_car_history AS
SELECT 
    c.nome_cliente,
    mc.nome_modelo,
    ch.id_chassis,
    os.id_ordem,
    os.data_abertura,
    p.nome_peca,
    op.quantidade,-- pegando valor somente caso nao seja preenchido
    IF NEW.valor_unitario IS NULL OR NEW.valor_unitario = 0 THEN
        SELECT preco INTO NEW.valor_unitario 
        FROM peca 
        WHERE id_peca = NEW.id_peca;
    END IF;
    op.valor_unitario,
    (op.quantidade * op.valor_unitario) AS subtotal
FROM cliente c
JOIN chassis ch ON c.id_cliente = ch.id_cliente
JOIN modelo_carro mc ON ch.id_modelo = mc.id_modelo
JOIN ordens_servico os ON ch.id_chassis = os.id_chassis
JOIN ordem_peca op ON os.id_ordem = op.id_ordem
JOIN peca p ON op.id_peca = p.id_peca;

-- store procedure - descontos

CREATE OR REPLACE PROCEDURE pr_desconto(discount_percent DECIMAL)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE ordens_servico
    SET valor_total = valor_total * (1 - discount_percent / 100)
    WHERE id_status != 3; -- somente aplica a status finalizado
    
    COMMIT; 
END;
$$;

-- To run it:
CALL pr_apply_holiday_discount(10.0);



---- testes

SELECT * FROM v_complete_car_history;






